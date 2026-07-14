"""Validated sample-batch commands and immutable ingestion results."""

from __future__ import annotations

import hashlib
import json
from typing import Literal, Self
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

InvalidReason = Literal[
    "low_confidence",
    "out_of_frame",
    "occlusion",
    "missing_fretboard",
    "wrong_hand",
]


class BatchDomainError(Exception):
    """Base domain error for sample-batch ingestion."""


class BatchSessionUnavailableError(BatchDomainError):
    """The requested session is absent or not owned by the actor."""


class BatchSessionNotActiveError(BatchDomainError):
    """Samples cannot be appended because the owned session is not active."""


class SampleSequenceConflictError(BatchDomainError):
    """The batch does not continue the persisted session sequence."""


class SampleIdentityConflictError(BatchDomainError):
    """A sample UUID or session sequence position is already persisted."""


class BatchPersistenceError(BatchDomainError):
    """Persisted batch state failed an internal application contract."""


class SessionSampleInput(BaseModel):
    """One structurally validated, physically untrusted interval sample."""

    model_config = ConfigDict(frozen=True, extra="ignore")

    id: UUID
    seq: int = Field(ge=0)
    is_valid: bool
    invalid_reason: InvalidReason | None = None
    placement_accuracy: float | None = Field(default=None, ge=0, le=1)
    confidence: float | None = Field(default=None, ge=0, le=1)
    interval_end_offset_ms: int = Field(ge=0)

    @model_validator(mode="after")
    def validate_validity_shape(self) -> Self:
        if self.is_valid:
            if self.invalid_reason is not None:
                raise ValueError("valid sample cannot have an invalid_reason")
            if self.placement_accuracy is None or self.confidence is None:
                raise ValueError("valid sample requires placement_accuracy and confidence")
        else:
            if self.invalid_reason is None:
                raise ValueError("invalid sample requires invalid_reason")
            if self.placement_accuracy is not None:
                raise ValueError("invalid sample cannot have placement_accuracy")
        return self


class IngestBatchCommand(BaseModel):
    """Non-empty, internally contiguous and monotonic sample chunk."""

    model_config = ConfigDict(frozen=True, extra="ignore")

    samples: tuple[SessionSampleInput, ...] = Field(min_length=1)

    @model_validator(mode="after")
    def validate_chunk_order(self) -> Self:
        ids = [sample.id for sample in self.samples]
        if len(ids) != len(set(ids)):
            raise ValueError("sample ids must be unique within a batch")

        for previous, current in zip(self.samples, self.samples[1:], strict=False):
            if current.seq != previous.seq + 1:
                raise ValueError("sample seq values must be contiguous and increasing")
            if current.interval_end_offset_ms <= previous.interval_end_offset_ms:
                raise ValueError("sample interval offsets must be strictly increasing")
        return self

    def request_hash(self, *, session_id: UUID) -> str:
        canonical = json.dumps(
            {
                "session_id": str(session_id),
                "samples": [sample.model_dump(mode="json") for sample in self.samples],
            },
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
        )
        return hashlib.sha256(f"ingest_batch\n{canonical}".encode()).hexdigest()


class IngestBatchResponse(BaseModel):
    model_config = ConfigDict(frozen=True)

    session_id: UUID
    accepted_count: int = Field(ge=1)
    first_seq: int = Field(ge=0)
    last_seq: int = Field(ge=0)


class IngestBatchExecutionResult(BaseModel):
    model_config = ConfigDict(frozen=True)

    response_status: int = Field(ge=100, le=599)
    response: IngestBatchResponse
