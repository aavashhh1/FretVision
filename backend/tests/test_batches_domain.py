"""Pure validation and hashing tests for sample-batch commands."""

from __future__ import annotations

from uuid import UUID

import pytest
from app.domain.batches import IngestBatchCommand, SessionSampleInput
from pydantic import ValidationError

SESSION_A = UUID("aaaaaaaa-0000-4000-8000-000000000001")
SESSION_B = UUID("bbbbbbbb-0000-4000-8000-000000000002")
SAMPLE_A = UUID("cccccccc-0000-4000-8000-000000000003")
SAMPLE_B = UUID("dddddddd-0000-4000-8000-000000000004")


def _valid_sample(
    *, sample_id: UUID = SAMPLE_A, seq: int = 0, offset: int = 2500
) -> dict[str, object]:
    return {
        "id": str(sample_id),
        "seq": seq,
        "is_valid": True,
        "placement_accuracy": 0.75,
        "confidence": 0.8,
        "interval_end_offset_ms": offset,
    }


def test_valid_and_invalid_sample_shapes_are_accepted() -> None:
    command = IngestBatchCommand.model_validate(
        {
            "samples": [
                _valid_sample(),
                {
                    "id": str(SAMPLE_B),
                    "seq": 1,
                    "is_valid": False,
                    "invalid_reason": "occlusion",
                    "confidence": 0.2,
                    "interval_end_offset_ms": 5000,
                },
            ]
        }
    )

    assert len(command.samples) == 2
    assert command.samples[1].placement_accuracy is None
    assert command.samples[1].confidence == 0.2


@pytest.mark.parametrize(
    "overrides",
    [
        {"invalid_reason": "occlusion"},
        {"placement_accuracy": None},
        {"confidence": None},
        {"is_valid": False, "invalid_reason": None, "placement_accuracy": None},
        {
            "is_valid": False,
            "invalid_reason": "occlusion",
            "placement_accuracy": 0.5,
        },
    ],
)
def test_invalid_sample_shapes_are_rejected(overrides: dict[str, object]) -> None:
    body = _valid_sample()
    body.update(overrides)
    with pytest.raises(ValidationError):
        SessionSampleInput.model_validate(body)


def test_batch_requires_unique_contiguous_monotonic_samples() -> None:
    with pytest.raises(ValidationError, match="unique"):
        IngestBatchCommand.model_validate(
            {"samples": [_valid_sample(), _valid_sample(seq=1, offset=5000)]}
        )

    with pytest.raises(ValidationError, match="contiguous"):
        IngestBatchCommand.model_validate(
            {
                "samples": [
                    _valid_sample(),
                    _valid_sample(sample_id=SAMPLE_B, seq=2, offset=5000),
                ]
            }
        )

    with pytest.raises(ValidationError, match="strictly increasing"):
        IngestBatchCommand.model_validate(
            {
                "samples": [
                    _valid_sample(),
                    _valid_sample(sample_id=SAMPLE_B, seq=1, offset=2500),
                ]
            }
        )


def test_request_hash_includes_path_session_and_ignores_body_identity() -> None:
    command = IngestBatchCommand.model_validate(
        {
            "session_id": str(SESSION_B),
            "user_id": str(SESSION_B),
            "samples": [_valid_sample()],
        }
    )

    assert command.model_dump() == {
        "samples": (
            {
                "id": SAMPLE_A,
                "seq": 0,
                "is_valid": True,
                "invalid_reason": None,
                "placement_accuracy": 0.75,
                "confidence": 0.8,
                "interval_end_offset_ms": 2500,
            },
        )
    }
    assert len(command.request_hash(session_id=SESSION_A)) == 64
    assert command.request_hash(session_id=SESSION_A) != command.request_hash(session_id=SESSION_B)
