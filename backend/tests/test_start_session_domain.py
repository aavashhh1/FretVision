"""Pure domain tests for validated start-session input and request hashing."""

from __future__ import annotations

from uuid import UUID

from app.domain.sessions import StartSessionCommand

EXERCISE_ID = UUID("10000000-0000-4000-8000-000000000001")
TARGET_ID = UUID("20000000-0000-4000-8000-000000000002")


def test_command_ignores_identity_and_reproducibility_fields() -> None:
    command = StartSessionCommand.model_validate(
        {
            "exercise_revision_id": str(EXERCISE_ID),
            "target_position_revision_id": str(TARGET_ID),
            "declared_interval_ms": 2500,
            "user_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "fretting_hand_snapshot": "right",
            "accuracy_metric_version": 999,
            "calibration_method": "client_value",
        }
    )

    assert command.model_dump() == {
        "exercise_revision_id": EXERCISE_ID,
        "target_position_revision_id": TARGET_ID,
        "declared_interval_ms": 2500,
    }


def test_request_hash_is_stable_and_operation_scoped() -> None:
    first = StartSessionCommand(
        exercise_revision_id=EXERCISE_ID,
        target_position_revision_id=TARGET_ID,
        declared_interval_ms=2500,
    )
    second = StartSessionCommand.model_validate(
        {
            "declared_interval_ms": 2500,
            "target_position_revision_id": str(TARGET_ID),
            "exercise_revision_id": str(EXERCISE_ID),
        }
    )

    assert first.request_hash() == second.request_hash()
    assert len(first.request_hash()) == 64
    assert (
        first.request_hash()
        != first.model_copy(update={"declared_interval_ms": 3000}).request_hash()
    )
