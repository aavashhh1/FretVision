"""Domain contract for user-scoped command idempotency."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from uuid import UUID


class IdempotencyError(Exception):
    """Base domain error for idempotency orchestration."""


class IdempotencyKeyConflictError(IdempotencyError):
    """A key was reused with a different canonical request hash."""


class IdempotencyRecordUnavailableError(IdempotencyError):
    """A reservation or completed response could not satisfy its contract."""


class AuthenticatedSubjectNotFoundError(IdempotencyError):
    """The verified subject no longer has a corresponding auth.users row."""


@dataclass(frozen=True, slots=True)
class NewIdempotencyReservation:
    record_id: UUID


@dataclass(frozen=True, slots=True)
class IdempotencyReplay:
    response_status: int
    response_body: dict[str, Any]


IdempotencyResolution = NewIdempotencyReservation | IdempotencyReplay
