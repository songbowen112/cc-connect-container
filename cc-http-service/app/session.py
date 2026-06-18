"""多轮会话:基于 ClaudeSDKClient 维护消息队列 + 响应队列。"""
from __future__ import annotations

import asyncio
import base64
import logging
import mimetypes
import os
import uuid
from typing import Any, AsyncIterator, Optional

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient

from .agent_service import _build_options, _serialize_message
from .schemas import QueryRequest, SessionSendRequest

log = logging.getLogger(__name__)

DEFAULT_WORK_DIR = "/home/vscode/cc-home"


class StreamingSession:
    """维护一个 ClaudeSDKClient 实例,支持外部 send + 监听 events。"""

    def __init__(self, session_id: str, options: ClaudeAgentOptions):
        self.session_id = session_id
        self.options = options
        self._client: Optional[ClaudeSDKClient] = None
        self._input_queue: asyncio.Queue[dict | None] = asyncio.Queue()
        self._output_queue: asyncio.Queue[dict] = asyncio.Queue()
        self._running = False
        self._task: asyncio.Task | None = None
        self._error: str | None = None

    async def start(self) -> None:
        self._client = ClaudeSDKClient(options=self.options)
        await self._client.__aenter__()
        self._running = True
        self._task = asyncio.create_task(self._process_loop())

    async def stop(self) -> None:
        self._running = False
        await self._input_queue.put(None)  # 通知后台循环退出
        if self._task and not self._task.done():
            try:
                # 等后台循环退出
                await asyncio.wait_for(self._task, timeout=5)
            except asyncio.TimeoutError:
                # 强制取消 + 杀子进程
                self._task.cancel()
                try:
                    await self._task
                except (asyncio.CancelledError, Exception):  # noqa: BLE001
                    pass
        if self._client:
            # 用 wait_for 包裹 __aexit__,防止它卡死时 stop() 永远不返回
            try:
                await asyncio.wait_for(
                    self._client.__aexit__(None, None, None), timeout=5
                )
            except asyncio.TimeoutError:
                log.warning(
                    "session %s __aexit__ timeout, force-closing", self.session_id
                )
            except Exception:  # noqa: BLE001
                pass
        # 把残留在队列里没消费的事件标记为流结束
        try:
            await self._output_queue.put(
                {"event": "session_closed", "data": {"session_id": self.session_id}}
            )
        except Exception:  # noqa: BLE001
            pass

    async def send(self, req: SessionSendRequest) -> None:
        if not self._running:
            raise RuntimeError(f"Session {self.session_id} is not running")
        payload = self._build_user_message(req.message, req.images)
        await self._input_queue.put(payload)

    async def events(self) -> AsyncIterator[dict]:
        """异步迭代器,产出所有待消费事件;超时时发心跳。"""
        while self._running or not self._output_queue.empty():
            try:
                event = await asyncio.wait_for(self._output_queue.get(), timeout=15)
                yield event
            except asyncio.TimeoutError:
                yield {
                    "event": "heartbeat",
                    "data": {"session_id": self.session_id},
                }
        # 流结束,补一个终止事件
        yield {
            "event": "session_closed",
            "data": {"session_id": self.session_id, "error": self._error},
        }

    # ------------------------------------------------------------------
    # 内部
    # ------------------------------------------------------------------
    async def _process_loop(self) -> None:
        assert self._client is not None
        per_turn_timeout = float(os.getenv("HTTP_TURN_TIMEOUT_SEC", "600"))
        try:
            while self._running:
                item = await self._input_queue.get()
                if item is None:
                    break
                try:
                    if item.get("is_multipart"):
                        await self._client.query(item["content"])
                    else:
                        await self._client.query(item["message"])
                    # 单轮 receive_response 有超时,卡死会强制中断
                    async with asyncio.timeout(per_turn_timeout):
                        async for response in self._client.receive_response():
                            await self._output_queue.put(_serialize_message(response))
                except asyncio.TimeoutError:
                    await self._output_queue.put(
                        {
                            "event": "error",
                            "data": {
                                "message": f"turn timeout after {per_turn_timeout}s",
                                "type": "TimeoutError",
                            },
                        }
                    )
                except Exception as e:  # noqa: BLE001
                    await self._output_queue.put(
                        {
                            "event": "error",
                            "data": {"message": str(e), "type": type(e).__name__},
                        }
                    )
                # 无论成功失败都补一个 turn_complete,让客户端知道这一轮结束了
                await self._output_queue.put(
                    {"event": "turn_complete", "data": {"session_id": self.session_id}}
                )
        except Exception as e:  # noqa: BLE001
            self._error = str(e)
            await self._output_queue.put(
                {"event": "error", "data": {"message": str(e), "type": type(e).__name__}}
            )
        finally:
            self._running = False

    @staticmethod
    def _build_user_message(message: str, images: list[str] | None) -> dict:
        """组装 SDK query 接受的入参。"""
        if not images:
            return {"message": message, "is_multipart": False}
        content: list[dict[str, Any]] = []
        for img_path in images:
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
        content.append({"type": "text", "text": message})
        return {"content": content, "is_multipart": True}


# ---------------------------------------------------------------------------
# Session 注册表(进程内)
# ---------------------------------------------------------------------------
class SessionManager:
    def __init__(self) -> None:
        self._sessions: dict[str, StreamingSession] = {}
        self._last_active: dict[str, float] = {}  # sid -> last touch time
        # 空闲超时(秒),默认 30 分钟;HTTP_SESSION_IDLE_TIMEOUT_SEC 可覆盖
        self._idle_timeout = float(os.getenv("HTTP_SESSION_IDLE_TIMEOUT_SEC", "1800"))
        # 总数上限,防 OOM;HTTP_SESSION_MAX 可覆盖
        self._max_sessions = int(os.getenv("HTTP_SESSION_MAX", "20"))
        # 后台 reaper 任务
        self._reaper_task: asyncio.Task | None = None

    async def create(self, init_options: ClaudeAgentOptions) -> StreamingSession:
        if len(self._sessions) >= self._max_sessions:
            # 先尝试回收一个空闲最久的
            await self._reap_idle_once(force=True)
            if len(self._sessions) >= self._max_sessions:
                raise RuntimeError(
                    f"too many active sessions (max {self._max_sessions}); "
                    "close some or raise HTTP_SESSION_MAX"
                )
        sid = uuid.uuid4().hex[:16]
        session = StreamingSession(sid, init_options)
        await session.start()
        self._sessions[sid] = session
        self._last_active[sid] = asyncio.get_event_loop().time()
        self._ensure_reaper()
        return session

    def get(self, sid: str) -> StreamingSession | None:
        s = self._sessions.get(sid)
        if s is not None:
            self._last_active[sid] = asyncio.get_event_loop().time()
        return s

    async def close(self, sid: str) -> bool:
        s = self._sessions.pop(sid, None)
        self._last_active.pop(sid, None)
        if not s:
            return False
        await s.stop()
        return True

    def list_ids(self) -> list[str]:
        return list(self._sessions.keys())

    def _ensure_reaper(self) -> None:
        """启动后台 reaper,定期回收空闲超时的 session。"""
        if self._reaper_task and not self._reaper_task.done():
            return
        self._reaper_task = asyncio.create_task(self._reaper_loop())

    async def _reaper_loop(self) -> None:
        """每 60s 检查一次,把空闲超时的 session 关掉。"""
        try:
            while self._sessions:
                await asyncio.sleep(60)
                await self._reap_idle_once(force=False)
        except asyncio.CancelledError:
            pass
        except Exception:  # noqa: BLE001
            log.exception("reaper loop error")

    async def _reap_idle_once(self, force: bool = False) -> None:
        """回收空闲 session。force=True 时,即使未超时也回收最老的(用于超限场景)。"""
        if not self._sessions:
            return
        now = asyncio.get_event_loop().time()
        victims: list[str] = []
        for sid, last in self._last_active.items():
            if sid not in self._sessions:
                continue
            if (now - last) > self._idle_timeout or force:
                victims.append(sid)
        # 非强制模式下不主动回收超限外的,只回收超时
        for sid in victims:
            s = self._sessions.get(sid)
            if s is not None:
                log.info("reaping idle session %s", sid)
                try:
                    await self.close(sid)
                except Exception:  # noqa: BLE001
                    log.exception("error closing session %s", sid)


# ---------------------------------------------------------------------------
# 给 router 用的工厂
# ---------------------------------------------------------------------------
def build_options_from_request(req: QueryRequest) -> ClaudeAgentOptions:
    return _build_options(req)
