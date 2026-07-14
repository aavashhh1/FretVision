"""SQL repository for owned active-session sample ingestion."""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

import asyncpg

from app.domain.batches import (
    BatchPersistenceError,
    BatchSessionNotActiveError,
    BatchSessionUnavailableError,
    IngestBatchCommand,
    SampleIdentityConflictError,
    SampleSequenceConflictError,
)

LOCK_OWNED_SESSION_SQL = """
SELECT id, lifecycle, declared_interval_ms
FROM public.sessions
WHERE id = $1 AND user_id = $2
FOR UPDATE
"""

SELECT_SAMPLE_TAIL_SQL = """
SELECT max(seq) AS last_seq,
       max(interval_end_offset_ms) AS last_interval_end_offset_ms
FROM public.session_samples
WHERE session_id = $1
"""

INSERT_SAMPLE_SQL = """
INSERT INTO public.session_samples (
  id,
  session_id,
  seq,
  is_valid,
  invalid_reason,
  placement_accuracy,
  confidence,
  interval_end_offset_ms
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
"""


@dataclass(frozen=True, slots=True)
class BatchSessionSnapshot:
    session_id: UUID
    declared_interval_ms: int


async def lock_owned_active_session(
    connection: asyncpg.Connection,
    *,
    session_id: UUID,
    user_id: UUID,
) -> BatchSessionSnapshot:
    """Lock an owned session and require it to be active."""
    record = await connection.fetchrow(LOCK_OWNED_SESSION_SQL, session_id, user_id)
    if record is None:
        raise BatchSessionUnavailableError("owned session was not found")
    if record["lifecycle"] != "active":
        raise BatchSessionNotActiveError("session is not active")
    declared_interval_ms = record["declared_interval_ms"]
    if not isinstance(declared_interval_ms, int):
        raise BatchPersistenceError("session interval failed its persistence contract")
    return BatchSessionSnapshot(
        session_id=UUID(str(record["id"])),
        declared_interval_ms=declared_interval_ms,
    )


async def append_sample_batch(
    connection: asyncpg.Connection,
    *,
    session: BatchSessionSnapshot,
    command: IngestBatchCommand,
) -> None:
    """Require ordered continuation, then insert every sample in the caller transaction."""
    tail = await connection.fetchrow(SELECT_SAMPLE_TAIL_SQL, session.session_id)
    if tail is None:
        raise BatchPersistenceError("session sample tail query returned no aggregate row")

    last_seq = tail["last_seq"]
    expected_first_seq = 0 if last_seq is None else int(last_seq) + 1
    first = command.samples[0]
    if first.seq != expected_first_seq:
        raise SampleSequenceConflictError(f"batch must begin at seq {expected_first_seq}")

    last_offset = tail["last_interval_end_offset_ms"]
    if last_offset is not None and first.interval_end_offset_ms <= int(last_offset):
        raise SampleSequenceConflictError(
            "batch interval offsets must continue the persisted monotonic sequence"
        )

    arguments = [
        (
            sample.id,
            session.session_id,
            sample.seq,
            sample.is_valid,
            sample.invalid_reason,
            sample.placement_accuracy,
            sample.confidence,
            sample.interval_end_offset_ms,
        )
        for sample in command.samples
    ]
    try:
        await connection.executemany(INSERT_SAMPLE_SQL, arguments)
    except asyncpg.UniqueViolationError as exc:
        raise SampleIdentityConflictError(
            "sample id or session sequence is already persisted"
        ) from exc
    except asyncpg.CheckViolationError as exc:
        raise BatchPersistenceError(
            "validated sample was rejected by the database contract"
        ) from exc
