"""FastAPI 应用入口。"""
from __future__ import annotations

import logging
import os
import signal
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from .routers import health, query, sessions as sessions_router

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("cc-http")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """启动时:注册 signal handler,优雅关闭所有 session。"""
    loop = asyncio.get_event_loop()

    def _shutdown(signum, _frame):
        log.warning("received signal %s, shutting down sessions...", signum)
        # 不能在 signal handler 里 await,创建 task 让事件循环处理
        for sid in list(sessions_router.manager._sessions.keys()):
            sess = sessions_router.manager._sessions.get(sid)
            if sess is not None:
                loop.create_task(sessions_router.manager.close(sid))

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, _shutdown, sig, None)
        except (NotImplementedError, RuntimeError):
            # Windows / 非主线程不支持 add_signal_handler,跳过
            signal.signal(sig, _shutdown)

    try:
        yield
    finally:
        # 关闭时:清理所有 session
        log.info("shutting down, closing %d sessions", len(sessions_router.manager._sessions))
        for sid in list(sessions_router.manager._sessions.keys()):
            try:
                await sessions_router.manager.close(sid)
            except Exception:  # noqa: BLE001
                log.exception("error closing session %s", sid)


import asyncio  # noqa: E402  -- 必须在 lifespan 里用,放在 import 段末


def create_app() -> FastAPI:
    app = FastAPI(
        title="Claude Code HTTP Service",
        version="1.0.0",
        description="把容器内的 Claude Code 暴露为 HTTP/SSE 接口",
        lifespan=lifespan,
    )
    app.include_router(health.router)
    app.include_router(query.router)
    app.include_router(sessions_router.router)

    @app.exception_handler(Exception)
    async def unhandled(request, exc):  # noqa: ARG001
        log.exception("unhandled error")
        return JSONResponse(
            status_code=500,
            content={"error": {"type": type(exc).__name__, "message": str(exc)}},
        )

    return app


app = create_app()
