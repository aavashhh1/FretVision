"""Authenticated session command routes."""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Header, Request
from fastapi.responses import JSONResponse

from app.auth.ownership import ActorDep
from app.domain.batches import IngestBatchCommand, IngestBatchResponse
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


@router.post(
    "/{session_id}/samples/batches",
    response_model=IngestBatchResponse,
    status_code=200,
)
async def ingest_batch(
    session_id: UUID,
    request: Request,
    actor: ActorDep,
    command: IngestBatchCommand,
    idempotency_key: IdempotencyKey,
) -> JSONResponse:
    """Append one ordered sample chunk in an idempotent transaction."""
    result = await request.app.state.services.ingest_batch.execute(
        owner_id=actor.user_id,
        session_id=session_id,
        idempotency_key=idempotency_key,
        command=command,
    )
    return JSONResponse(
        status_code=result.response_status,
        content=result.response.model_dump(mode="json"),
    )
