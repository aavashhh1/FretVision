"""SQL repository for the approved user-scoped idempotency algorithm."""

from __future__ import annotations

import json
from collections.abc import Mapping
from typing import Any
from uuid import UUID

import asyncpg

from app.domain.idempotency import (
    AuthenticatedSubjectNotFoundError,
    IdempotencyKeyConflictError,
    IdempotencyRecordUnavailableError,
    IdempotencyReplay,
    IdempotencyResolution,
    NewIdempotencyReservation,
)

RESERVE_START_SESSION_SQL = """
INSERT INTO public.idempotency_records (
  user_id, operation, idempotency_key, request_hash, expires_at
)
VALUES (
  $1, 'start_session', $2, $3,
  now() + pg_catalog.make_interval(secs => $4::double precision)
)
ON CONFLICT (user_id, operation, idempotency_key) DO NOTHING
RETURNING id
"""

LOCK_EXISTING_START_SESSION_SQL = """
SELECT id, request_hash, state, response_status, response_body
FROM public.idempotency_records
WHERE user_id = $1
  AND operation = 'start_session'
  AND idempotency_key = $2
FOR UPDATE
"""

COMPLETE_START_SESSION_SQL = """
UPDATE public.idempotency_records
SET session_id = $2,
    state = 'completed',
    response_status = $3,
    response_body = $4::jsonb
WHERE id = $1 AND state = 'processing'
RETURNING id
"""


def _decode_response_body(value: object) -> dict[str, Any]:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError as exc:
            raise IdempotencyRecordUnavailableError(
                "stored idempotency response is not valid JSON"
            ) from exc
    if not isinstance(value, Mapping):
        raise IdempotencyRecordUnavailableError("stored idempotency response is not a JSON object")
    return {str(key): item for key, item in value.items()}


async def reserve_start_session(
    connection: asyncpg.Connection,
    *,
    user_id: UUID,
    idempotency_key: str,
    request_hash: str,
    ttl_seconds: int,
) -> IdempotencyResolution:
    """Reserve a key, or lock and return its completed response."""
    try:
        inserted_id = await connection.fetchval(
            RESERVE_START_SESSION_SQL,
            user_id,
            idempotency_key,
            request_hash,
            ttl_seconds,
        )
    except asyncpg.ForeignKeyViolationError as exc:
        raise AuthenticatedSubjectNotFoundError("authenticated subject no longer exists") from exc

    if inserted_id is not None:
        return NewIdempotencyReservation(record_id=UUID(str(inserted_id)))

    record = await connection.fetchrow(
        LOCK_EXISTING_START_SESSION_SQL,
        user_id,
        idempotency_key,
    )
    if record is None:
        raise IdempotencyRecordUnavailableError(
            "conflicting idempotency record disappeared before it could be locked"
        )
    if record["request_hash"] != request_hash:
        raise IdempotencyKeyConflictError(
            "idempotency key was already used for a different request"
        )
    if record["state"] != "completed":
        raise IdempotencyRecordUnavailableError(
            "locked idempotency record did not reach completed state"
        )
    status = record["response_status"]
    if not isinstance(status, int):
        raise IdempotencyRecordUnavailableError(
            "completed idempotency record has no response status"
        )
    return IdempotencyReplay(
        response_status=status,
        response_body=_decode_response_body(record["response_body"]),
    )


async def complete_start_session(
    connection: asyncpg.Connection,
    *,
    record_id: UUID,
    session_id: UUID,
    response_status: int,
    response_body: dict[str, Any],
) -> None:
    """Atomically attach the session and exact stored response to a reservation."""
    completed_id = await connection.fetchval(
        COMPLETE_START_SESSION_SQL,
        record_id,
        session_id,
        response_status,
        json.dumps(response_body, sort_keys=True, separators=(",", ":")),
    )
    if completed_id is None:
        raise IdempotencyRecordUnavailableError("idempotency reservation could not be completed")
