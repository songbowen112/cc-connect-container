"""单次查询:同步 + SSE 流式。"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
import tempfile
import uuid
from typing import Any

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from sse_starlette.sse import EventSourceResponse

from ..agent_service import run_query_stream
from ..auth import require_auth
from ..schemas import FileUploadResponse, QueryRequest

router = APIRouter(prefix="/v1", tags=["query"])

# 图片上传目录(容器内)。挂载到宿主机方便测试。
UPLOAD_DIR = os.getenv("HTTP_UPLOAD_DIR", "/home/vscode/cc-http-uploads")


def _ensure_upload_dir() -> None:
    os.makedirs(UPLOAD_DIR, exist_ok=True)


@router.post("/query")
async def query_sync(
    req: QueryRequest,
    _: str = Depends(require_auth),
) -> JSONResponse:
    """阻塞模式:等所有事件跑完,把最后一条 result 事件作为响应返回。

    适合一次性脚本调用,简单省事。
    """
    final: dict[str, Any] | None = None
    last_assistant_text: str = ""
    gen = run_query_stream(req)
    try:
        async for event in gen:
            if event["event"] == "result":
                final = event["data"]
            elif event["event"] == "assistant":
                for block in event["data"].get("content", []):
                    if block.get("type") == "text":
                        last_assistant_text += block.get("text", "")
            elif event["event"] == "error":
                return JSONResponse(
                    status_code=500,
                    content={"error": event["data"]},
                )
    finally:
        # 显式 close,确保 SDK 释放 claude 子进程(异步生成器 GC 不可靠)
        await gen.aclose()
    return JSONResponse(
        content={
            "result": (final or {}).get("result"),
            "session_id": (final or {}).get("session_id"),
            "total_cost_usd": (final or {}).get("total_cost_usd"),
            "is_error": (final or {}).get("is_error"),
            "num_turns": (final or {}).get("num_turns"),
            "last_text": last_assistant_text,
        }
    )


@router.post("/query/stream")
async def query_stream(
    req: QueryRequest,
    _: str = Depends(require_auth),
) -> EventSourceResponse:
    """SSE 流式:边生成边推。"""

    async def event_generator():
        # 必须手动管理 generator 生命周期,async for 不会自动 close
        # (PEP 533 推迟);客户端断开时 aclose 才能触发 SDK 释放 claude 子进程
        gen = run_query_stream(req)
        try:
            async for event in gen:
                yield {
                    "event": event.get("event", "message"),
                    "data": json.dumps(event.get("data", {}), ensure_ascii=False),
                }
        except asyncio.CancelledError:
            # 客户端断开
            raise
        finally:
            await gen.aclose()

    return EventSourceResponse(event_generator())


@router.post("/files", response_model=FileUploadResponse)
async def upload_file(
    file: UploadFile = File(...),
    _: str = Depends(require_auth),
) -> FileUploadResponse:
    """上传文件(图片等)到容器内固定目录,返回容器内可访问的绝对路径。

    拿到 path 后,在 query 请求的 images 字段里传这个 path 即可让 cc 看到。
    """
    _ensure_upload_dir()
    safe_name = file.filename or "upload.bin"
    # 防路径穿越:只取文件名
    safe_name = os.path.basename(safe_name)
    # 加随机前缀避免冲突
    final_name = f"{uuid.uuid4().hex[:8]}_{safe_name}"
    full_path = os.path.join(UPLOAD_DIR, final_name)
    with open(full_path, "wb") as f:
        shutil.copyfileobj(file.file, f)
    size = os.path.getsize(full_path)
    return FileUploadResponse(filename=final_name, path=full_path, size=size)
