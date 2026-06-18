#!/usr/bin/env python3
"""uvicorn 启动入口。"""
import os

import uvicorn

if __name__ == "__main__":
    uvicorn.run(
        "app.main:app",
        host=os.getenv("HTTP_HOST", "0.0.0.0"),
        port=int(os.getenv("HTTP_PORT", "8765")),
        log_level=os.getenv("LOG_LEVEL", "info").lower(),
        # SSE 需要长连接,关掉 access log 噪音(按需开)
        access_log=os.getenv("HTTP_ACCESS_LOG", "false").lower() == "true",
    )
