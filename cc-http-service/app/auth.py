"""Bearer Token 鉴权。

从环境变量 HTTP_API_KEY 读取 token(空字符串 = 关闭鉴权,仅本机调试用)。
开启后所有 /v1/* 接口必须带 Authorization: Bearer <token>。
"""
from __future__ import annotations

import os

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

_security = HTTPBearer(auto_error=False)


def get_api_key() -> str:
    return os.getenv("HTTP_API_KEY", "").strip()


def is_auth_enabled() -> bool:
    return bool(get_api_key())


async def require_auth(
    credentials: HTTPAuthorizationCredentials | None = Depends(_security),
) -> str:
    """FastAPI Depends 入口。未配置 HTTP_API_KEY 时放行,否则校验 Bearer token。"""
    expected = get_api_key()
    if not expected:
        return ""

    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing Bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if credentials.credentials != expected:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API key",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return credentials.credentials
