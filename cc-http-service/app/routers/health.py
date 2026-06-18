"""健康检查 + 鉴权开关状态。"""
from __future__ import annotations

from fastapi import APIRouter, Depends

from ..auth import is_auth_enabled, require_auth

router = APIRouter(tags=["health"])


@router.get("/health")
async def health() -> dict:
    return {
        "status": "ok",
        "auth_enabled": is_auth_enabled(),
    }


@router.get("/whoami")
async def whoami(_: str = Depends(require_auth)) -> dict:
    """仅用于测试 token 是否生效。"""
    return {"ok": True}
