"""Deterministic unit tests for lazy, idempotent profile provisioning (U11 / ADR 06).

No live database: a fake connection records the exact SQL and parameters the repository
issues, so the assertions check the real statements in ``app.repositories.profiles``
rather than a copy of them.
"""

from __future__ import annotations

import inspect
from typing import Any, get_type_hints
from uuid import UUID

import asyncpg
import pytest
from app.domain.profiles import (
    ProfileIdentityNotFoundError,
    ProfileSnapshot,
    ProfileSnapshotUnavailableError,
)
from app.repositories.profiles import (
    INSERT_PROFILE_SQL,
    SELECT_PROFILE_SQL,
    ensure_profile,
)
from pydantic import ValidationError

USER_ID = UUID("aaaaaaaa-0000-4000-8000-00000000000a")


class FakeConnection:
    """Records every call the repository makes, in order."""

    def __init__(
        self,
        *,
        row: dict[str, Any] | None,
        insert_error: Exception | None = None,
    ) -> None:
        self.row = row
        self.insert_error = insert_error
        self.calls: list[tuple[str, str, tuple[Any, ...]]] = []

    async def execute(self, sql: str, *args: Any) -> str:
        self.calls.append(("execute", sql, args))
        if self.insert_error is not None:
            raise self.insert_error
        return "INSERT 0 1"

    async def fetchrow(self, sql: str, *args: Any) -> dict[str, Any] | None:
        self.calls.append(("fetchrow", sql, args))
        return self.row


def _row(**overrides: Any) -> dict[str, Any]:
    row: dict[str, Any] = {
        "user_id": USER_ID,
        "display_name": None,
        "fretting_hand": "left",
    }
    row.update(overrides)
    return row


# --------------------------------------------------------------------------- #
# 1. Missing profile: INSERT ... DO NOTHING, then SELECT, then return.
# --------------------------------------------------------------------------- #
async def test_missing_profile_inserts_then_selects() -> None:
    connection = FakeConnection(row=_row())

    snapshot = await ensure_profile(connection, user_id=USER_ID)  # type: ignore[arg-type]

    assert [(kind, sql) for kind, sql, _ in connection.calls] == [
        ("execute", INSERT_PROFILE_SQL),
        ("fetchrow", SELECT_PROFILE_SQL),
    ]
    assert snapshot == ProfileSnapshot(
        user_id=USER_ID, display_name=None, fretting_hand="left"
    )


# --------------------------------------------------------------------------- #
# 2. Existing profile: provisioning never overwrites existing values.
# --------------------------------------------------------------------------- #
async def test_existing_profile_is_never_overwritten() -> None:
    connection = FakeConnection(
        row=_row(display_name="Existing Name", fretting_hand="right")
    )

    snapshot = await ensure_profile(connection, user_id=USER_ID)  # type: ignore[arg-type]

    # The returned snapshot preserves what was already stored.
    assert snapshot.display_name == "Existing Name"
    assert snapshot.fretting_hand == "right"

    # Only two statements ran, and the write is a conflict no-op: nothing in the
    # provisioning path can assign display_name or fretting_hand.
    assert len(connection.calls) == 2
    insert_sql = connection.calls[0][1].upper()
    assert "ON CONFLICT (USER_ID) DO NOTHING" in " ".join(insert_sql.split())
    assert "DO UPDATE" not in insert_sql
    assert "SET" not in insert_sql
    assert "UPDATE" not in insert_sql
    assert "DISPLAY_NAME" not in insert_sql
    assert "FRETTING_HAND" not in insert_sql


# --------------------------------------------------------------------------- #
# 3. user_id travels as a positional SQL parameter, never interpolated.
# --------------------------------------------------------------------------- #
async def test_user_id_is_passed_as_positional_sql_parameter() -> None:
    connection = FakeConnection(row=_row())

    await ensure_profile(connection, user_id=USER_ID)  # type: ignore[arg-type]

    for _, sql, args in connection.calls:
        assert args == (USER_ID,)
        assert "$1" in sql
        assert str(USER_ID) not in sql  # never string-formatted into the statement


# --------------------------------------------------------------------------- #
# 4. ProfileSnapshot is immutable.
# --------------------------------------------------------------------------- #
def test_profile_snapshot_is_immutable() -> None:
    snapshot = ProfileSnapshot(user_id=USER_ID, display_name=None, fretting_hand="left")
    with pytest.raises(ValidationError):
        snapshot.display_name = "Mutated"  # type: ignore[misc]
    with pytest.raises(ValidationError):
        snapshot.fretting_hand = "right"  # type: ignore[misc]


# --------------------------------------------------------------------------- #
# 5. Missing / invalid row after INSERT + SELECT raises a typed domain error.
# --------------------------------------------------------------------------- #
async def test_missing_row_after_insert_raises_snapshot_unavailable() -> None:
    connection = FakeConnection(row=None)

    with pytest.raises(ProfileSnapshotUnavailableError):
        await ensure_profile(connection, user_id=USER_ID)  # type: ignore[arg-type]


async def test_invalid_row_raises_snapshot_unavailable_from_validation_error() -> None:
    connection = FakeConnection(row=_row(fretting_hand="ambidextrous"))

    with pytest.raises(ProfileSnapshotUnavailableError) as excinfo:
        await ensure_profile(connection, user_id=USER_ID)  # type: ignore[arg-type]

    assert isinstance(excinfo.value.__cause__, ValidationError)


async def test_foreign_key_violation_raises_identity_not_found() -> None:
    connection = FakeConnection(
        row=_row(), insert_error=asyncpg.ForeignKeyViolationError("fk violation")
    )

    with pytest.raises(ProfileIdentityNotFoundError) as excinfo:
        await ensure_profile(connection, user_id=USER_ID)  # type: ignore[arg-type]

    # The raw asyncpg exception is chained, never allowed to escape the repository.
    assert isinstance(excinfo.value.__cause__, asyncpg.ForeignKeyViolationError)
    assert len(connection.calls) == 1  # no SELECT after a failed insert


# --------------------------------------------------------------------------- #
# 6. The contract accepts no request DTO: ownership arrives only as a UUID.
# --------------------------------------------------------------------------- #
def test_ensure_profile_takes_connection_and_keyword_only_uuid_user_id() -> None:
    parameters = inspect.signature(ensure_profile).parameters
    assert list(parameters) == ["connection", "user_id"]

    user_id_param = parameters["user_id"]
    assert user_id_param.kind is inspect.Parameter.KEYWORD_ONLY
    assert user_id_param.default is inspect.Parameter.empty

    hints = get_type_hints(ensure_profile)
    assert hints["user_id"] is UUID  # a bare UUID — no body, payload, or command DTO
    assert hints["return"] is ProfileSnapshot
