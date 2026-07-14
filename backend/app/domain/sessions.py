"""Start-session command and immutable session snapshots."""

from __future__ import annotations

import hashlib
import json
from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from app.domain.profiles import FrettingHand


class StartSessionDomainError(Exception):
    """Base domain error for start-session orchestration."""


class RevisionPairUnavailableError(StartSessionDomainError):
    """The requested published exercise/target revision pair is unavailable."""


class SessionSnapshotUnavailableError(StartSessionDomainError):
    """A created or activated session failed its read-model contract."""


class StartSessionCommand(BaseModel):
    """Validated client command; identity and reproducibility inputs are ignored."""

    model_config = ConfigDict(frozen=True, extra="ignore")

    exercise_revision_id: UUID
    target_position_revision_id: UUID
    declared_interval_ms: int = Field(ge=2000, le=5000)

    def request_hash(self) -> str:
        """Return the operation-scoped SHA-256 hash of canonical validated input."""
        canonical_body = json.dumps(
            self.model_dump(mode="json"),
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
        )
        return hashlib.sha256(f"start_session\n{canonical_body}".encode()).hexdigest()


class RevisionSnapshot(BaseModel):
    model_config = ConfigDict(frozen=True)

    exercise_revision_id: UUID
    target_position_revision_id: UUID
    accuracy_metric_version: int = Field(ge=1)
    calibration_method: Literal["manual_4pt"]


class StartSessionResponse(BaseModel):
    model_config = ConfigDict(frozen=True)

    session_id: UUID
    lifecycle: Literal["active"]
    exercise_revision_id: UUID
    target_position_revision_id: UUID
    declared_interval_ms: int = Field(ge=2000, le=5000)
    activated_at: datetime
    fretting_hand_snapshot: FrettingHand
    accuracy_metric_version: int = Field(ge=1)
    calibration_method: Literal["manual_4pt"]


class StartSessionExecutionResult(BaseModel):
    """HTTP-neutral result retaining the stored response status for replay."""

    model_config = ConfigDict(frozen=True)

    response_status: int = Field(ge=100, le=599)
    response: StartSessionResponse
