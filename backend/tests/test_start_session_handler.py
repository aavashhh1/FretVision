"""Command-layer tests for transaction order, rollback, replay, and mappings."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

import pytest
from app.commands import start_session as module
from app.commands.start_session import StartSessionHandler
from app.domain.idempotency import (
    IdempotencyKeyConflictError,
    IdempotencyReplay,
    NewIdempotencyReservation,
)
from app.domain.profiles import ProfileSnapshot
from app.domain.sessions import (
    RevisionSnapshot,
    StartSessionCommand,
    StartSessionResponse,
)
from app.errors import IdempotencyConflictHttpError

USER_ID = UUID("aaaaaaaa-0000-4000-8000-000000000001")
EXERCISE_ID = UUID("bbbbbbbb-0000-4000-8000-000000000002")
TARGET_ID = UUID("cccccccc-0000-4000-8000-000000000003")
SESSION_ID = UUID("dddddddd-0000-4000-8000-000000000004")
RECORD_ID = UUID("eeeeeeee-0000-4000-8000-000000000005")
ACTIVATED_AT = datetime(2026, 7, 14, 12, 0, tzinfo=UTC)


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


def _command() -> StartSessionCommand:
    return StartSessionCommand(
        exercise_revision_id=EXERCISE_ID,
        target_position_revision_id=TARGET_ID,
        declared_interval_ms=2500,
    )


def _response() -> StartSessionResponse:
    return StartSessionResponse(
        session_id=SESSION_ID,
        lifecycle="active",
        exercise_revision_id=EXERCISE_ID,
        target_position_revision_id=TARGET_ID,
        declared_interval_ms=2500,
        activated_at=ACTIVATED_AT,
        fretting_hand_snapshot="left",
        accuracy_metric_version=1,
        calibration_method="manual_4pt",
    )


async def test_success_runs_full_order_and_commits(monkeypatch: pytest.MonkeyPatch) -> None:
    events: list[str] = []
    database = FakeDatabase(events)

    async def reserve(*args: Any, **kwargs: Any) -> NewIdempotencyReservation:
        events.append("reserve")
        assert args[0] is database.connection
        assert kwargs["user_id"] == USER_ID
        return NewIdempotencyReservation(RECORD_ID)

    async def profile(*args: Any, **kwargs: Any) -> ProfileSnapshot:
        events.append("profile")
        return ProfileSnapshot(user_id=USER_ID, display_name=None, fretting_hand="left")

    async def revision(*args: Any, **kwargs: Any) -> RevisionSnapshot:
        events.append("revision")
        return RevisionSnapshot(
            exercise_revision_id=EXERCISE_ID,
            target_position_revision_id=TARGET_ID,
            accuracy_metric_version=1,
            calibration_method="manual_4pt",
        )

    async def create(*args: Any, **kwargs: Any) -> StartSessionResponse:
        events.append("create_activate")
        assert kwargs["user_id"] == USER_ID
        return _response()

    async def complete(*args: Any, **kwargs: Any) -> None:
        events.append("complete_idempotency")
        assert kwargs["record_id"] == RECORD_ID
        assert kwargs["session_id"] == SESSION_ID

    monkeypatch.setattr(module, "reserve_start_session", reserve)
    monkeypatch.setattr(module, "ensure_profile", profile)
    monkeypatch.setattr(module, "get_revision_snapshot", revision)
    monkeypatch.setattr(module, "create_and_activate_session", create)
    monkeypatch.setattr(module, "complete_start_session", complete)

    handler = StartSessionHandler(  # type: ignore[arg-type]
        database=database,
        idempotency_ttl_seconds=86400,
    )
    result = await handler.execute(
        owner_id=USER_ID,
        idempotency_key="start-key-1",
        command=_command(),
    )

    assert result.response == _response()
    assert events == [
        "begin",
        "reserve",
        "profile",
        "revision",
        "create_activate",
        "complete_idempotency",
        "commit",
    ]


async def test_replay_rolls_back_before_return(monkeypatch: pytest.MonkeyPatch) -> None:
    events: list[str] = []
    database = FakeDatabase(events)

    async def reserve(*args: Any, **kwargs: Any) -> IdempotencyReplay:
        events.append("reserve")
        return IdempotencyReplay(
            response_status=201,
            response_body=_response().model_dump(mode="json"),
        )

    monkeypatch.setattr(module, "reserve_start_session", reserve)
    handler = StartSessionHandler(  # type: ignore[arg-type]
        database=database,
        idempotency_ttl_seconds=86400,
    )

    result = await handler.execute(
        owner_id=USER_ID,
        idempotency_key="start-key-1",
        command=_command(),
    )

    assert result.response == _response()
    assert events == ["begin", "reserve", "rollback"]


async def test_hash_conflict_rolls_back_and_maps_409(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    events: list[str] = []
    database = FakeDatabase(events)

    async def reserve(*args: Any, **kwargs: Any) -> None:
        events.append("reserve")
        raise IdempotencyKeyConflictError

    monkeypatch.setattr(module, "reserve_start_session", reserve)
    handler = StartSessionHandler(  # type: ignore[arg-type]
        database=database,
        idempotency_ttl_seconds=86400,
    )

    with pytest.raises(IdempotencyConflictHttpError) as excinfo:
        await handler.execute(
            owner_id=USER_ID,
            idempotency_key="start-key-1",
            command=_command(),
        )

    assert excinfo.value.status_code == 409
    assert events == ["begin", "reserve", "rollback"]


async def test_replay_rejects_unexpected_stored_status(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    events: list[str] = []
    database = FakeDatabase(events)

    async def reserve(*args: Any, **kwargs: Any) -> IdempotencyReplay:
        return IdempotencyReplay(
            response_status=200,
            response_body=_response().model_dump(mode="json"),
        )

    monkeypatch.setattr(module, "reserve_start_session", reserve)
    handler = StartSessionHandler(  # type: ignore[arg-type]
        database=database,
        idempotency_ttl_seconds=86400,
    )

    with pytest.raises(RuntimeError, match="unexpected status"):
        await handler.execute(
            owner_id=USER_ID,
            idempotency_key="start-key-1",
            command=_command(),
        )

    assert events == ["begin", "rollback"]
