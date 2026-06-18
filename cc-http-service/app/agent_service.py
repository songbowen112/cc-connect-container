"""Claude Agent SDK 封装:把异步迭代器转成 dict,供 SSE 推送。"""
from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Any, AsyncIterator

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    HookContext,
    ResultMessage,
    SystemMessage,
    TextBlock,
    ToolResultBlock,
    ToolUseBlock,
    query,
)
from claude_agent_sdk.types import UserMessage

from .schemas import HookMatcher, HooksConfig, McpServerConfig, QueryRequest, SubagentDef

log = logging.getLogger(__name__)

DEFAULT_WORK_DIR = "/home/vscode/cc-home"


# ---------------------------------------------------------------------------
# 消息序列化
# ---------------------------------------------------------------------------
def _serialize_block(block: Any) -> dict[str, Any]:
    """把 SDK content block 序列化成 dict。"""
    if isinstance(block, TextBlock):
        return {"type": "text", "text": block.text}
    if isinstance(block, ToolUseBlock):
        return {
            "type": "tool_use",
            "id": getattr(block, "id", None),
            "name": block.name,
            "input": getattr(block, "input", {}),
        }
    if isinstance(block, ToolResultBlock):
        return {
            "type": "tool_result",
            "tool_use_id": getattr(block, "tool_use_id", None),
            "content": getattr(block, "content", None),
            "is_error": getattr(block, "is_error", None),
        }
    # 兜底:尽力取已知字段
    return {
        "type": getattr(block, "type", "unknown"),
        "raw": str(block),
    }


def _serialize_message(message: Any) -> dict[str, Any]:
    """把 SDK 消息对象转成 SSE 事件 dict。"""
    if isinstance(message, SystemMessage):
        return {
            "event": "system",
            "data": {
                "subtype": getattr(message, "subtype", None),
                "session_id": _extract_session_id(message),
                "details": getattr(message, "data", {}) or {},
            },
        }
    if isinstance(message, AssistantMessage):
        return {
            "event": "assistant",
            "data": {
                "content": [_serialize_block(b) for b in (message.content or [])],
                "parent_tool_use_id": getattr(message, "parent_tool_use_id", None),
            },
        }
    if isinstance(message, ResultMessage):
        return {
            "event": "result",
            "data": {
                "subtype": getattr(message, "subtype", None),
                "duration_ms": getattr(message, "duration_ms", None),
                "duration_api_ms": getattr(message, "duration_api_ms", None),
                "is_error": getattr(message, "is_error", None),
                "num_turns": getattr(message, "num_turns", None),
                "session_id": getattr(message, "session_id", None),
                "total_cost_usd": getattr(message, "total_cost_usd", None),
                "result": getattr(message, "result", None),
            },
        }
    # UserMessage / 其他:尽量序列化
    return {
        "event": "message",
        "data": {"raw": str(message), "type": type(message).__name__},
    }


def _extract_session_id(system_message: SystemMessage) -> str | None:
    """system init 事件里 session_id 在 data 字段里。"""
    data = getattr(system_message, "data", None) or {}
    return data.get("session_id")


# ---------------------------------------------------------------------------
# 请求 → ClaudeAgentOptions
# ---------------------------------------------------------------------------
def _build_mcp_servers(
    mcp_servers: dict[str, McpServerConfig] | None,
) -> dict[str, Any] | None:
    if not mcp_servers:
        return None
    out: dict[str, Any] = {}
    for name, cfg in mcp_servers.items():
        entry: dict[str, Any] = {}
        if cfg.type:
            entry["type"] = cfg.type
        if cfg.command:
            entry["command"] = cfg.command
        if cfg.args:
            entry["args"] = cfg.args
        if cfg.env:
            entry["env"] = cfg.env
        if cfg.url:
            entry["url"] = cfg.url
        if cfg.headers:
            entry["headers"] = cfg.headers
        out[name] = entry
    return out


def _build_agents(agents: dict[str, SubagentDef] | None) -> dict[str, Any] | None:
    if not agents:
        return None
    return {
        name: {k: v for k, v in defn.model_dump(exclude_none=True).items()}
        for name, defn in agents.items()
    }


def _build_hooks(hooks: HooksConfig | None) -> dict[str, Any] | None:
    """构造 SDK hooks 配置。

    SDK 接受的 hooks 格式:
        {"PreToolUse": [HookMatcher(matcher="Bash", hooks=[async fn, ...])]}

    我们把每个用户传入的 ``command`` 包成 async function,SDK 调用时:
    1. 序列化 hook input 到 JSON,stdin 喂给 command
    2. command 退出码 0 + stdout 为 JSON:把 stdout 作为决策返回
    3. command 退出码非 0:忽略,继续默认行为
    4. 用户没传 command:兜底写一个"全部允许"的 hook(SDK 仍需 hooks 列表非空)
    """
    if not hooks:
        return None

    out: dict[str, list[Any]] = {}
    for event_name in ("PreToolUse", "PostToolUse", "Stop", "SubagentStop"):
        matchers = getattr(hooks, event_name, None)
        if not matchers:
            continue
        out[event_name] = []
        for m in matchers:
            out[event_name].append(_make_matcher(m))
    return out or None


def _make_matcher(m: HookMatcher) -> Any:
    """把用户传入的 HookMatcher 转成 SDK 的 HookMatcher dataclass。"""
    from claude_agent_sdk import HookMatcher as SDKHookMatcher

    cb = _make_command_callback(m.command)
    return SDKHookMatcher(
        matcher=m.matcher,
        hooks=[cb],
        timeout=m.timeout,
    )


def _make_command_callback(command: str | None):
    """把 shell command 包成 async HookCallback。

    协议:
      stdin:  JSON 字符串 {"hook_event_name":..., "input":{...}, "tool_use_id":...}
      stdout: 可选 JSON 决策(SDK 的 HookJSONOutput 结构),例如:
              {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                      "permissionDecision": "deny",
                                      "permissionDecisionReason": "..."}}
              退出码 0 表示采纳,非 0 表示忽略输出用默认行为。
    """
    import asyncio
    import json as _json
    import subprocess

    async def hook_cb(input_data, tool_use_id, context):  # noqa: ARG001
        if not command:
            return {}  # 默认放行
        try:
            proc = await asyncio.create_subprocess_exec(
                command,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            payload = {
                "hook_event_name": getattr(input_data, "hook_event_name", None),
                "input": _coerce_to_jsonable(input_data),
                "tool_use_id": tool_use_id,
            }
            try:
                stdout, _ = await asyncio.wait_for(
                    proc.communicate(_json.dumps(payload).encode()),
                    timeout=30,
                )
            except asyncio.TimeoutError:
                proc.kill()
                return {}
            if proc.returncode != 0 or not stdout:
                return {}
            return _json.loads(stdout.decode())
        except Exception:
            return {}

    return hook_cb


def _coerce_to_jsonable(obj: Any) -> Any:
    """把 SDK 的 dataclass / TypedDict 递归转成 JSON 友好的 dict。"""
    if obj is None or isinstance(obj, (str, int, float, bool)):
        return obj
    if isinstance(obj, (list, tuple)):
        return [_coerce_to_jsonable(x) for x in obj]
    if isinstance(obj, dict):
        return {k: _coerce_to_jsonable(v) for k, v in obj.items()}
    # dataclass
    if hasattr(obj, "__dataclass_fields__"):
        return {
            k: _coerce_to_jsonable(getattr(obj, k))
            for k in obj.__dataclass_fields__
        }
    return str(obj)


def _build_options(req: QueryRequest) -> ClaudeAgentOptions:
    """把 QueryRequest 翻译成 SDK 接受的 ClaudeAgentOptions。"""
    # 未指定 permission_mode 时默认 bypassPermissions,避免云端无人值守时
    # 读 ~/.claude/CLAUDE.md 等触发权限确认导致挂死
    perm = req.permission_mode or os.getenv("HTTP_DEFAULT_PERMISSION_MODE", "bypassPermissions")

    opts_kwargs: dict[str, Any] = {
        "permission_mode": perm,
        "cwd": req.work_dir or DEFAULT_WORK_DIR,
    }
    if req.model:
        opts_kwargs["model"] = req.model
    if req.allowed_tools:
        opts_kwargs["allowed_tools"] = req.allowed_tools
    if req.system_prompt:
        opts_kwargs["system_prompt"] = req.system_prompt
    if req.mcp_servers:
        opts_kwargs["mcp_servers"] = _build_mcp_servers(req.mcp_servers)
    if req.agents:
        opts_kwargs["agents"] = _build_agents(req.agents)
    hooks = _build_hooks(req.hooks)
    if hooks:
        opts_kwargs["hooks"] = hooks
    if req.extra_options:
        opts_kwargs.update(req.extra_options)

    # 默认用系统装的 claude(更轻,且配置/插件共享);用户可以通过
    # extra_options={"cli_path": "..."} 覆盖
    if "cli_path" not in opts_kwargs:
        system_claude = _find_system_claude()
        if system_claude:
            opts_kwargs["cli_path"] = system_claude

    return ClaudeAgentOptions(**opts_kwargs)


def _find_system_claude() -> str | None:
    """查找系统装的 claude CLI(优先 nvm/系统 bin,避免 SDK 用 bundled 版本)。"""
    import shutil

    candidates = [
        "/home/vscode/.nvm/versions/node/v24.14.0/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]
    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return shutil.which("claude")


# ---------------------------------------------------------------------------
# 公共 API
# ---------------------------------------------------------------------------
async def run_query_stream(req: QueryRequest) -> AsyncIterator[dict[str, Any]]:
    """单次查询,异步产出 SSE 事件 dict。

    行为:
    - 优先使用 query() 简单模式
    - 整个迭代有总超时(默认 10 分钟,可由 HTTP_QUERY_TIMEOUT_SEC 覆盖)
    - 任何错误立即 yield error 事件并退出,不让 SDK 异常冒到 FastAPI 500
    - 确保 SDK 异步生成器被正确关闭(释放 claude 子进程句柄)
    """
    options = _build_options(req)
    total_timeout = float(os.getenv("HTTP_QUERY_TIMEOUT_SEC", "600"))

    # 把 prompt + 可选图片组装成 SDK 接受的 messages 格式
    prompt_content = req.prompt
    if req.images:
        prompt_content = _format_prompt_with_images(req.prompt, req.images)

    gen = None
    try:
        gen = query(prompt=prompt_content, options=options)
        async with asyncio.timeout(total_timeout):
            async for message in gen:
                yield _serialize_message(message)
    except asyncio.TimeoutError:
        yield {
            "event": "error",
            "data": {
                "message": f"query timeout after {total_timeout}s",
                "type": "TimeoutError",
            },
        }
    except asyncio.CancelledError:
        # 客户端断开,不用 yield,直接退出
        raise
    except Exception as e:  # noqa: BLE001
        log.exception("run_query_stream error")
        yield {
            "event": "error",
            "data": {"message": str(e), "type": type(e).__name__},
        }
    finally:
        # 关闭 SDK 异步生成器(SDK 0.2.x:这会发 EOF 给 claude 子进程,让它退出)
        if gen is not None:
            try:
                await gen.aclose()
            except Exception:  # noqa: BLE001
                pass


def _format_prompt_with_images(prompt: str, images: list[str]) -> Any:
    """把 prompt + 图片组装成 SDK query 接受的格式。

    claude-agent-sdk 的 query() 接受 str 或 AsyncIterable[dict];当含图片时
    改成 UserMessage 列表结构(content blocks)。
    """
    content: list[dict[str, Any]] = []
    for img_path in images:
        # SDK 0.1.x 通过 content block + image source 传图
        # 这里用文件路径方式:把图作为 base64 嵌进去
        import base64
        import mimetypes

        if not os.path.isfile(img_path):
            raise FileNotFoundError(f"Image not found: {img_path}")
        mime, _ = mimetypes.guess_type(img_path)
        mime = mime or "image/png"
        with open(img_path, "rb") as f:
            data = base64.standard_b64encode(f.read()).decode("ascii")
        content.append(
            {
                "type": "image",
                "source": {"type": "base64", "media_type": mime, "data": data},
            }
        )
    content.append({"type": "text", "text": prompt})
    return [{"type": "user", "message": {"role": "user", "content": content}}]
