"""Unit tests for revision lookup and created-to-active session persistence."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any
from uuid import UUID

import pytest
from app.domain.profiles import ProfileSnapshot
from app.domain.sessions import (
    RevisionPairUnavailableError,
    RevisionSnapshot,
    StartSessionCommand,
)
from app.repositories.sessions import (
    ACTIVATE_SESSION_SQL,
    INSERT_SESSION_CREATED_SQL,
    SELECT_REVISION_SNAPSHOT_SQL,
    create_and_activate_session,
    get_revision_snapshot,
)

USER_ID = UUID("aaaaaaaa-0000-4000-8000-000000000001")
EXERCISE_ID = UUID("bbbbbbbb-0000-4000-8000-000000000002")
TARGET_ID = UUID("cccccccc-0000-4000-8000-000000000003")
SESSION_ID = UUID("dddddddd-0000-4000-8000-000000000004")
ACTIVATED_AT = datetime(2026, 7, 14, 12, 0, tzinfo=UTC)


class FakeConnection:
    def __init__(self, *, fetchval: Any = None, rows: list[dict[str, Any] | None]) -> None:
        self.fetchval_result = fetchval
        self.rows = list(rows)
        self.calls: list[tuple[str, str, tuple[Any, ...]]] = []

    async def fetchval(self, sql: str, *args: Any) -> Any:
        self.calls.append(("fetchval", sql, args))
        return self.fetchval_result

    async def fetchrow(self, sql: str, *args: Any) -> dict[str, Any] | None:
        self.calls.append(("fetchrow", sql, args))
        return self.rows.pop(0)


async def test_revision_snapshot_requires_published_matching_pair() -> None:
    connection = FakeConnection(
        rows=[
            {
                "exercise_revision_id": EXERCISE_ID,
                "target_position_revision_id": TARGET_ID,
                "accuracy_metric_version": 1,
                "calibration_method": "manual_4pt",
            }
        ]
    )

    snapshot = await get_revision_snapshot(
        connection,  # type: ignore[arg-type]
        exercise_revision_id=EXERCISE_ID,
        target_position_revision_id=TARGET_ID,
    )

    assert snapshot.accuracy_metric_version == 1
    assert connection.calls == [
        (
            "fetchrow",
            SELECT_REVISION_SNAPSHOT_SQL,
            (EXERCISE_ID, TARGET_ID),
        )
    ]


async def test_unavailable_revision_pair_is_domain_error() -> None:
    connection = FakeConnection(rows=[None])
    with pytest.raises(RevisionPairUnavailableError):
        await get_revision_snapshot(
            connection,  # type: ignore[arg-type]
            exercise_revision_id=EXERCISE_ID,
            target_position_revision_id=TARGET_ID,
        )


async def test_session_is_inserted_created_then_activated() -> None:
    command = StartSessionCommand(
        exercise_revision_id=EXERCISE_ID,
        target_position_revision_id=TARGET_ID,
        declared_interval_ms=2500,
    )
    profile = ProfileSnapshot(
        user_id=USER_ID,
        display_name="Player",
        fretting_hand="right",
    )
    revision = RevisionSnapshot(
        exercise_revision_id=EXERCISE_ID,
        target_position_revision_id=TARGET_ID,
        accuracy_metric_version=1,
        calibration_method="manual_4pt",
    )
    connection = FakeConnection(
        fetchval=SESSION_ID,
        rows=[
            {
                "session_id": SESSION_ID,
                "lifecycle": "active",
                "exercise_revision_id": EXERCISE_ID,
                "target_position_revision_id": TARGET_ID,
                "declared_interval_ms": 2500,
                "activated_at": ACTIVATED_AT,
                "fretting_hand_snapshot": "right",
                "accuracy_metric_version": 1,
                "calibration_method": "manual_4pt",
            }
        ],
    )

    response = await create_and_activate_session(
        connection,  # type: ignore[arg-type]
        user_id=USER_ID,
        command=command,
        profile=profile,
        revision=revision,
    )

    assert response.session_id == SESSION_ID
    assert response.lifecycle == "active"
    assert response.fretting_hand_snapshot == "right"
    assert [call[1] for call in connection.calls] == [
        INSERT_SESSION_CREATED_SQL,
        ACTIVATE_SESSION_SQL,
    ]
    assert connection.calls[0][2] == (
        USER_ID,
        EXERCISE_ID,
        TARGET_ID,
        "right",
        1,
        "manual_4pt",
        2500,
    )
