"""请求/响应模型。"""
from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

# 权限模式参考 SDK:default / acceptEdits / plan / bypassPermissions / dontAsk / auto
PermissionMode = Literal[
    "default", "acceptEdits", "plan", "bypassPermissions", "dontAsk", "auto"
]


class HookMatcher(BaseModel):
    """SDK hooks 配置。

    透传给 SDK,SDK 要求 hooks 是 Python 函数列表(非简单字符串 action)。
    HTTP API 暂时只接受 ``command`` 形式的回调:
        {
          "matcher": "Write|Edit",
          "command": "/usr/local/bin/my-hook.sh"
        }
    SDK 端的实现细节参见 _build_hooks。
    """

    matcher: str = "*"
    command: str | None = Field(default=None, description="本地可执行文件路径,SDK 调用它处理 hook")
    timeout: float | None = None


class HooksConfig(BaseModel):
    PreToolUse: list[HookMatcher] | None = None
    PostToolUse: list[HookMatcher] | None = None
    Stop: list[HookMatcher] | None = None
    SubagentStop: list[HookMatcher] | None = None


class SubagentDef(BaseModel):
    description: str
    prompt: str
    tools: list[str] | None = None
    model: str | None = None


class McpServerConfig(BaseModel):
    """MCP 服务器配置,支持 stdio/http/sse 三种传输。"""

    type: str | None = None  # stdio | http | sse
    command: str | None = None
    args: list[str] | None = None
    env: dict[str, str] | None = None
    url: str | None = None
    headers: dict[str, str] | None = None


class QueryRequest(BaseModel):
    prompt: str = Field(..., description="用户消息")
    work_dir: str | None = Field(default=None, description="Claude Code 工作目录,默认 /home/vscode/cc-home")
    model: str | None = None
    permission_mode: PermissionMode | None = None
    allowed_tools: list[str] | None = None
    system_prompt: str | None = None
    hooks: HooksConfig | None = Field(
        default=None,
        description="生命周期 hook。command 形式:SDK 会 spawn 进程传 stdin JSON",
    )
    agents: dict[str, SubagentDef] | None = None
    mcp_servers: dict[str, McpServerConfig] | None = None
    images: list[str] | None = Field(
        default=None,
        description="容器内图片绝对路径列表(图片需先放到挂载目录里,或通过 /v1/files 上传)",
    )
    extra_options: dict[str, Any] | None = None


class SessionCreateRequest(BaseModel):
    work_dir: str | None = None
    model: str | None = None
    permission_mode: PermissionMode | None = None
    allowed_tools: list[str] | None = None
    system_prompt: str | None = None


class SessionSendRequest(BaseModel):
    message: str
    images: list[str] | None = None


class FileUploadResponse(BaseModel):
    filename: str
    path: str  # 容器内可访问的绝对路径
    size: int
