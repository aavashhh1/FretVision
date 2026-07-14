"""Command-layer tests for atomic ingest-batch ordering and error mappings."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any
from uuid import UUID

import pytest
from app.commands import ingest_batch as module
from app.commands.ingest_batch import IngestBatchHandler
from app.domain.batches import (
    BatchSessionUnavailableError,
    IngestBatchCommand,
    IngestBatchResponse,
    SampleSequenceConflictError,
)
from app.domain.idempotency import IdempotencyReplay, NewIdempotencyReservation
from app.errors import SampleBatchConflictHttpError, SessionNotFoundHttpError
from app.repositories.batches import BatchSessionSnapshot

USER_ID = UUID("aaaaaaaa-0000-4000-8000-000000000001")
SESSION_ID = UUID("bbbbbbbb-0000-4000-8000-000000000002")
SAMPLE_ID = UUID("cccccccc-0000-4000-8000-000000000003")
RECORD_ID = UUID("dddddddd-0000-4000-8000-000000000004")


class FakeDatabase:
    def __init__(self, events: list[str]) -> None:
        self.events = events
        self.connection = object()

    @asynccontextmanager
    async def transaction(self) -> AsyncIterator[Any]:
        self.events.append("begin")
        try:
            yield self.connection
        except BaseException:
            self.events.append("rollback")
            raise
        else:
            self.events.append("commit")


def _command() -> IngestBatchCommand:
    return IngestBatchCommand.model_validate(
        {
            "samples": [
                {
                    "id": SAMPLE_ID,
                    "seq": 0,
                    "is_valid": True,
                    "placement_accuracy": 0.8,
                    "confidence": 0.9,
                    "interval_end_offset_ms": 2500,
                }
            ]
        }
    )


async def test_success_orders_transaction_and_commits(monkeypatch: pytest.MonkeyPatch) -> None:
    events: list[str] = []
    database = FakeDatabase(events)

    async def reserve(*args: Any, **kwargs: Any) -> NewIdempotencyReservation:
        events.append("reserve")
        assert kwargs["user_id"] == USER_ID
        return NewIdempotencyReservation(RECORD_ID)

    async def lock(*args: Any, **kwargs: Any) -> BatchSessionSnapshot:
        events.append("lock_session")
        assert kwargs["user_id"] == USER_ID
        return BatchSessionSnapshot(SESSION_ID, 2500)

    async def append(*args: Any, **kwargs: Any) -> None:
        events.append("append_samples")

    async def complete(*args: Any, **kwargs: Any) -> None:
        events.append("complete_idempotency")
        assert kwargs["session_id"] == SESSION_ID
        assert kwargs["response_status"] == 200

    monkeypatch.setattr(module, "reserve_ingest_batch", reserve)
    monkeypatch.setattr(module, "lock_owned_active_session", lock)
    monkeypatch.setattr(module, "append_sample_batch", append)
    monkeypatch.setattr(module, "complete_ingest_batch", complete)

    handler = IngestBatchHandler(  # type: ignore[arg-type]
        database=database,
        idempotency_ttl_seconds=86400,
    )
    result = await handler.execute(
        owner_id=USER_ID,
        session_id=SESSION_ID,
        idempotency_key="batch-key-1",
        command=_command(),
    )

    assert result.response == IngestBatchResponse(
        session_id=SESSION_ID,
        accepted_count=1,
        first_seq=0,
        last_seq=0,
    )
    assert events == [
        "begin",
        "reserve",
        "lock_session",
        "append_samples",
        "complete_idempotency",
        "commit",
    ]


async def test_replay_rolls_back_before_return(monkeypatch: pytest.MonkeyPatch) -> None:
    events: list[str] = []
    database = FakeDatabase(events)
    response = IngestBatchResponse(
        session_id=SESSION_ID,
        accepted_count=1,
        first_seq=0,
        last_seq=0,
    )

    async def reserve(*args: Any, **kwargs: Any) -> IdempotencyReplay:
        events.append("reserve")
        return IdempotencyReplay(
            response_status=200,
            response_body=response.model_dump(mode="json"),
        )

    monkeypatch.setattr(module, "reserve_ingest_batch", reserve)
    handler = IngestBatchHandler(  # type: ignore[arg-type]
        database=database,
        idempotency_ttl_seconds=86400,
    )
    result = await handler.execute(
        owner_id=USER_ID,
        session_id=SESSION_ID,
        idempotency_key="batch-key-1",
        command=_command(),
    )

    assert result.response == response
    assert events == ["begin", "reserve", "rollback"]


@pytest.mark.parametrize(
    ("raised", "mapped"),
    [
        (BatchSessionUnavailableError(), SessionNotFoundHttpError),
        (SampleSequenceConflictError("gap"), SampleBatchConflictHttpError),
    ],
)
async def test_domain_failures_roll_back_and_map(
    monkeypatch: pytest.MonkeyPatch,
    raised: Exception,
    mapped: type[Exception],
) -> None:
    events: list[str] = []
    database = FakeDatabase(events)

    async def reserve(*args: Any, **kwargs: Any) -> NewIdempotencyReservation:
        events.append("reserve")
        return NewIdempotencyReservation(RECORD_ID)

    async def lock(*args: Any, **kwargs: Any) -> BatchSessionSnapshot:
        events.append("lock_session")
        if isinstance(raised, BatchSessionUnavailableError):
            raise raised
        return BatchSessionSnapshot(SESSION_ID, 2500)

    async def append(*args: Any, **kwargs: Any) -> None:
        events.append("append_samples")
        raise raised

    monkeypatch.setattr(module, "reserve_ingest_batch", reserve)
    monkeypatch.setattr(module, "lock_owned_active_session", lock)
    monkeypatch.setattr(module, "append_sample_batch", append)
    handler = IngestBatchHandler(  # type: ignore[arg-type]
        database=database,
        idempotency_ttl_seconds=86400,
    )

    with pytest.raises(mapped):
        await handler.execute(
            owner_id=USER_ID,
            session_id=SESSION_ID,
            idempotency_key="batch-key-1",
            command=_command(),
        )
    assert events[-1] == "rollback"
