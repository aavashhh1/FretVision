"""Unit tests for idempotency reservation, replay, conflict, and completion SQL."""

from __future__ import annotations

import json
from typing import Any
from uuid import UUID

import asyncpg
import pytest
from app.domain.idempotency import (
    AuthenticatedSubjectNotFoundError,
    IdempotencyKeyConflictError,
    IdempotencyReplay,
    NewIdempotencyReservation,
)
from app.repositories.idempotency import (
    COMPLETE_START_SESSION_SQL,
    LOCK_EXISTING_START_SESSION_SQL,
    RESERVE_START_SESSION_SQL,
    complete_start_session,
    reserve_start_session,
)

USER_ID = UUID("aaaaaaaa-0000-4000-8000-000000000001")
RECORD_ID = UUID("bbbbbbbb-0000-4000-8000-000000000002")
SESSION_ID = UUID("cccccccc-0000-4000-8000-000000000003")
REQUEST_HASH = "a" * 64


class FakeConnection:
    def __init__(
        self,
        *,
        fetchvals: list[Any] | None = None,
        row: dict[str, Any] | None = None,
        fetchval_error: Exception | None = None,
    ) -> None:
        self.fetchvals = list(fetchvals or [])
        self.row = row
        self.fetchval_error = fetchval_error
        self.calls: list[tuple[str, str, tuple[Any, ...]]] = []

    async def fetchval(self, sql: str, *args: Any) -> Any:
        self.calls.append(("fetchval", sql, args))
        if self.fetchval_error is not None:
            raise self.fetchval_error
        return self.fetchvals.pop(0) if self.fetchvals else None

    async def fetchrow(self, sql: str, *args: Any) -> dict[str, Any] | None:
        self.calls.append(("fetchrow", sql, args))
        return self.row


async def test_new_key_returns_reservation() -> None:
    connection = FakeConnection(fetchvals=[RECORD_ID])

    result = await reserve_start_session(
        connection,  # type: ignore[arg-type]
        user_id=USER_ID,
        idempotency_key="start-key-1",
        request_hash=REQUEST_HASH,
        ttl_seconds=86400,
    )

    assert result == NewIdempotencyReservation(record_id=RECORD_ID)
    assert connection.calls == [
        (
            "fetchval",
            RESERVE_START_SESSION_SQL,
            (USER_ID, "start-key-1", REQUEST_HASH, 86400),
        )
    ]


async def test_completed_key_returns_stored_json_replay() -> None:
    connection = FakeConnection(
        fetchvals=[None],
        row={
            "id": RECORD_ID,
            "request_hash": REQUEST_HASH,
            "state": "completed",
            "response_status": 201,
            "response_body": json.dumps({"session_id": str(SESSION_ID)}),
        },
    )

    result = await reserve_start_session(
        connection,  # type: ignore[arg-type]
        user_id=USER_ID,
        idempotency_key="start-key-1",
        request_hash=REQUEST_HASH,
        ttl_seconds=86400,
    )

    assert result == IdempotencyReplay(
        response_status=201,
        response_body={"session_id": str(SESSION_ID)},
    )
    assert connection.calls[1][1] == LOCK_EXISTING_START_SESSION_SQL


async def test_same_key_with_different_hash_is_conflict() -> None:
    connection = FakeConnection(
        fetchvals=[None],
        row={
            "id": RECORD_ID,
            "request_hash": "b" * 64,
            "state": "completed",
            "response_status": 201,
            "response_body": "{}",
        },
    )

    with pytest.raises(IdempotencyKeyConflictError):
        await reserve_start_session(
            connection,  # type: ignore[arg-type]
            user_id=USER_ID,
            idempotency_key="start-key-1",
            request_hash=REQUEST_HASH,
            ttl_seconds=86400,
        )


async def test_missing_auth_subject_is_domain_error() -> None:
    connection = FakeConnection(
        fetchval_error=asyncpg.ForeignKeyViolationError("missing auth user")
    )

    with pytest.raises(AuthenticatedSubjectNotFoundError):
        await reserve_start_session(
            connection,  # type: ignore[arg-type]
            user_id=USER_ID,
            idempotency_key="start-key-1",
            request_hash=REQUEST_HASH,
            ttl_seconds=86400,
        )


async def test_completion_stores_canonical_json_and_session_id() -> None:
    connection = FakeConnection(fetchvals=[RECORD_ID])

    await complete_start_session(
        connection,  # type: ignore[arg-type]
        record_id=RECORD_ID,
        session_id=SESSION_ID,
        response_status=201,
        response_body={"z": 1, "a": 2},
    )

    assert connection.calls == [
        (
            "fetchval",
            COMPLETE_START_SESSION_SQL,
            (RECORD_ID, SESSION_ID, 201, '{"a":2,"z":1}'),
        )
    ]
