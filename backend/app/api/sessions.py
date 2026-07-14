"""Authenticated session command routes."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Header, Request
from fastapi.responses import JSONResponse

from app.auth.ownership import ActorDep
from app.domain.sessions import StartSessionCommand, StartSessionResponse

router = APIRouter(prefix="/sessions", tags=["sessions"])

IdempotencyKey = Annotated[
    str,
    Header(alias="Idempotency-Key", min_length=8, max_length=200),
]


@router.post("", response_model=StartSessionResponse, status_code=201)
async def start_session(
    request: Request,
    actor: ActorDep,
    command: StartSessionCommand,
    idempotency_key: IdempotencyKey,
) -> JSONResponse:
    """Create and activate a session in one idempotent database transaction."""
    result = await request.app.state.services.start_session.execute(
        owner_id=actor.user_id,
        idempotency_key=idempotency_key,
        command=command,
    )
    return JSONResponse(
        status_code=result.response_status,
        content=result.response.model_dump(mode="json"),
    )
