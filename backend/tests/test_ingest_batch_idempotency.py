"""Unit tests for ingest-batch idempotency reservation and completion."""

from __future__ import annotations

import json
from typing import Any
from uuid import UUID

import pytest
from app.domain.idempotency import IdempotencyKeyConflictError, IdempotencyReplay
from app.repositories.idempotency import (
    COMPLETE_INGEST_BATCH_SQL,
    LOCK_EXISTING_INGEST_BATCH_SQL,
    RESERVE_INGEST_BATCH_SQL,
    complete_ingest_batch,
    reserve_ingest_batch,
)

USER_ID = UUID("aaaaaaaa-0000-4000-8000-000000000001")
RECORD_ID = UUID("bbbbbbbb-0000-4000-8000-000000000002")
SESSION_ID = UUID("cccccccc-0000-4000-8000-000000000003")
REQUEST_HASH = "a" * 64


class FakeConnection:
    def __init__(self, *, values: list[Any], row: dict[str, Any] | None = None) -> None:
        self.values = list(values)
        self.row = row
        self.calls: list[tuple[str, str, tuple[Any, ...]]] = []

    async def fetchval(self, sql: str, *args: Any) -> Any:
        self.calls.append(("fetchval", sql, args))
        return self.values.pop(0)

    async def fetchrow(self, sql: str, *args: Any) -> dict[str, Any] | None:
        self.calls.append(("fetchrow", sql, args))
        return self.row


async def test_completed_batch_key_replays_stored_response() -> None:
    body = {"session_id": str(SESSION_ID), "accepted_count": 2, "first_seq": 0, "last_seq": 1}
    connection = FakeConnection(
        values=[None],
        row={
            "id": RECORD_ID,
            "request_hash": REQUEST_HASH,
            "state": "completed",
            "response_status": 200,
            "response_body": json.dumps(body),
        },
    )

    result = await reserve_ingest_batch(
        connection,  # type: ignore[arg-type]
        user_id=USER_ID,
        idempotency_key="batch-key-1",
        request_hash=REQUEST_HASH,
        ttl_seconds=86400,
    )

    assert result == IdempotencyReplay(response_status=200, response_body=body)
    assert connection.calls[0][1] == RESERVE_INGEST_BATCH_SQL
    assert connection.calls[1][1] == LOCK_EXISTING_INGEST_BATCH_SQL


async def test_batch_key_hash_conflict_is_rejected() -> None:
    connection = FakeConnection(
        values=[None],
        row={
            "id": RECORD_ID,
            "request_hash": "b" * 64,
            "state": "completed",
            "response_status": 200,
            "response_body": "{}",
        },
    )
    with pytest.raises(IdempotencyKeyConflictError):
        await reserve_ingest_batch(
            connection,  # type: ignore[arg-type]
            user_id=USER_ID,
            idempotency_key="batch-key-1",
            request_hash=REQUEST_HASH,
            ttl_seconds=86400,
        )


async def test_batch_completion_attaches_session_and_exact_json() -> None:
    connection = FakeConnection(values=[RECORD_ID])
    await complete_ingest_batch(
        connection,  # type: ignore[arg-type]
        record_id=RECORD_ID,
        session_id=SESSION_ID,
        response_status=200,
        response_body={"last_seq": 1, "accepted_count": 2},
    )
    assert connection.calls == [
        (
            "fetchval",
            COMPLETE_INGEST_BATCH_SQL,
            (RECORD_ID, SESSION_ID, 200, '{"accepted_count":2,"last_seq":1}'),
        )
    ]
