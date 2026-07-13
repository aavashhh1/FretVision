"""Liveness and readiness endpoints."""

from __future__ import annotations

from fastapi import APIRouter, Request

router = APIRouter(tags=["health"])


@router.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness: the process is up. Returns 200 even when the database is down."""
    return {"status": "ok"}


@router.get("/readyz")
async def readyz(request: Request) -> dict[str, str]:
    """Readiness: acquire a connection and run ``SELECT 1``. 503 on failure."""
    services = request.app.state.services
    await services.database.check_ready()
    return {"status": "ready"}
