"""Unit tests for owned session locking and ordered batch persistence."""

from __future__ import annotations

from typing import Any
from uuid import UUID

import asyncpg
import pytest
from app.domain.batches import (
    BatchSessionNotActiveError,
    BatchSessionUnavailableError,
    IngestBatchCommand,
    SampleIdentityConflictError,
    SampleSequenceConflictError,
)
from app.repositories.batches import (
    INSERT_SAMPLE_SQL,
    LOCK_OWNED_SESSION_SQL,
    SELECT_SAMPLE_TAIL_SQL,
    BatchSessionSnapshot,
    append_sample_batch,
    lock_owned_active_session,
)

USER_ID = UUID("aaaaaaaa-0000-4000-8000-000000000001")
SESSION_ID = UUID("bbbbbbbb-0000-4000-8000-000000000002")
SAMPLE_A = UUID("cccccccc-0000-4000-8000-000000000003")
SAMPLE_B = UUID("dddddddd-0000-4000-8000-000000000004")


class FakeConnection:
    def __init__(
        self,
        *,
        rows: list[dict[str, Any] | None],
        executemany_error: Exception | None = None,
    ) -> None:
        self.rows = list(rows)
        self.executemany_error = executemany_error
        self.calls: list[tuple[str, str, Any]] = []

    async def fetchrow(self, sql: str, *args: Any) -> dict[str, Any] | None:
        self.calls.append(("fetchrow", sql, args))
        return self.rows.pop(0)

    async def executemany(self, sql: str, args: Any) -> None:
        materialized = list(args)
        self.calls.append(("executemany", sql, materialized))
        if self.executemany_error is not None:
            raise self.executemany_error


def _command(*, first_seq: int = 0, first_offset: int = 2500) -> IngestBatchCommand:
    return IngestBatchCommand.model_validate(
        {
            "samples": [
                {
                    "id": SAMPLE_A,
                    "seq": first_seq,
                    "is_valid": True,
                    "placement_accuracy": 0.8,
                    "confidence": 0.9,
                    "interval_end_offset_ms": first_offset,
                },
                {
                    "id": SAMPLE_B,
                    "seq": first_seq + 1,
                    "is_valid": False,
                    "invalid_reason": "occlusion",
                    "interval_end_offset_ms": first_offset + 2500,
                },
            ]
        }
    )


async def test_lock_requires_owned_active_session() -> None:
    missing = FakeConnection(rows=[None])
    with pytest.raises(BatchSessionUnavailableError):
        await lock_owned_active_session(
            missing,
            session_id=SESSION_ID,
            user_id=USER_ID,  # type: ignore[arg-type]
        )

    terminal = FakeConnection(
        rows=[{"id": SESSION_ID, "lifecycle": "completed", "declared_interval_ms": 2500}]
    )
    with pytest.raises(BatchSessionNotActiveError):
        await lock_owned_active_session(
            terminal,
            session_id=SESSION_ID,
            user_id=USER_ID,  # type: ignore[arg-type]
        )

    active = FakeConnection(
        rows=[{"id": SESSION_ID, "lifecycle": "active", "declared_interval_ms": 2500}]
    )
    snapshot = await lock_owned_active_session(
        active,
        session_id=SESSION_ID,
        user_id=USER_ID,  # type: ignore[arg-type]
    )
    assert snapshot == BatchSessionSnapshot(SESSION_ID, 2500)
    assert active.calls[0][1] == LOCK_OWNED_SESSION_SQL


async def test_append_requires_persisted_sequence_and_offset_continuation() -> None:
    session = BatchSessionSnapshot(SESSION_ID, 2500)
    sequence_gap = FakeConnection(rows=[{"last_seq": 0, "last_interval_end_offset_ms": 2500}])
    with pytest.raises(SampleSequenceConflictError, match="seq 1"):
        await append_sample_batch(
            sequence_gap,  # type: ignore[arg-type]
            session=session,
            command=_command(first_seq=2, first_offset=5000),
        )

    offset_regression = FakeConnection(rows=[{"last_seq": 1, "last_interval_end_offset_ms": 5000}])
    with pytest.raises(SampleSequenceConflictError, match="offset"):
        await append_sample_batch(
            offset_regression,  # type: ignore[arg-type]
            session=session,
            command=_command(first_seq=2, first_offset=5000),
        )


async def test_append_inserts_all_samples_in_order() -> None:
    connection = FakeConnection(rows=[{"last_seq": None, "last_interval_end_offset_ms": None}])
    session = BatchSessionSnapshot(SESSION_ID, 2500)

    await append_sample_batch(
        connection,  # type: ignore[arg-type]
        session=session,
        command=_command(),
    )

    assert [call[1] for call in connection.calls] == [
        SELECT_SAMPLE_TAIL_SQL,
        INSERT_SAMPLE_SQL,
    ]
    inserted = connection.calls[1][2]
    assert inserted[0] == (SAMPLE_A, SESSION_ID, 0, True, None, 0.8, 0.9, 2500)
    assert inserted[1] == (SAMPLE_B, SESSION_ID, 1, False, "occlusion", None, None, 5000)


async def test_unique_violation_becomes_sample_identity_conflict() -> None:
    connection = FakeConnection(
        rows=[{"last_seq": None, "last_interval_end_offset_ms": None}],
        executemany_error=asyncpg.UniqueViolationError("duplicate sample"),
    )
    with pytest.raises(SampleIdentityConflictError):
        await append_sample_batch(
            connection,  # type: ignore[arg-type]
            session=BatchSessionSnapshot(SESSION_ID, 2500),
            command=_command(),
        )
