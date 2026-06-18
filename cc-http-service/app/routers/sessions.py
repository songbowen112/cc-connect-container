"""多轮会话路由。"""
from __future__ import annotations

import json

from fastapi import APIRouter, Depends, HTTPException
from sse_starlette.sse import EventSourceResponse

from ..auth import require_auth
from ..schemas import SessionCreateRequest, SessionSendRequest
from ..session import SessionManager, build_options_from_request

router = APIRouter(prefix="/v1/sessions", tags=["sessions"])
manager = SessionManager()


@router.post("/create")
async def create_session(
    req: SessionCreateRequest,
    _: str = Depends(require_auth),
) -> dict:
    """创建一个常驻 session,返回 session_id。

    session 在服务端维持一个 ClaudeSDKClient,后续 send 通过同一 session 续接上下文。
    """
    # 把 SessionCreateRequest 复用成 QueryRequest 走同一套 options 构造逻辑
    from ..schemas import QueryRequest

    options = build_options_from_request(
        QueryRequest(
            prompt="",  # 不在 create 时发消息
            work_dir=req.work_dir,
            model=req.model,
            permission_mode=req.permission_mode,
            allowed_tools=req.allowed_tools,
            system_prompt=req.system_prompt,
        )
    )
    session = await manager.create(options)
    return {
        "session_id": session.session_id,
        "work_dir": options.cwd,
    }


@router.get("/list")
async def list_sessions(_: str = Depends(require_auth)) -> dict:
    return {"sessions": manager.list_ids()}


@router.post("/{session_id}/send")
async def send_message(
    session_id: str,
    req: SessionSendRequest,
    _: str = Depends(require_auth),
) -> dict:
    session = manager.get(session_id)
    if not session:
        raise HTTPException(status_code=404, detail=f"Session {session_id} not found")
    try:
        await session.send(req)
    except FileNotFoundError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return {"ok": True, "session_id": session_id}


@router.get("/{session_id}/events")
async def stream_events(
    session_id: str,
    _: str = Depends(require_auth),
) -> EventSourceResponse:
    """订阅 session 的事件流。SSE 长连接,客户端边 send 边 listen。"""
    session = manager.get(session_id)
    if not session:
        raise HTTPException(status_code=404, detail=f"Session {session_id} not found")

    async def event_generator():
        gen = session.events()
        try:
            async for event in gen:
                yield {
                    "event": event.get("event", "message"),
                    "data": json.dumps(event.get("data", {}), ensure_ascii=False),
                }
        finally:
            await gen.aclose()

    return EventSourceResponse(event_generator())


@router.delete("/{session_id}")
async def close_session(
    session_id: str,
    _: str = Depends(require_auth),
) -> dict:
    ok = await manager.close(session_id)
    if not ok:
        raise HTTPException(status_code=404, detail=f"Session {session_id} not found")
    return {"ok": True, "session_id": session_id}
