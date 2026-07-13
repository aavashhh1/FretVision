"""Verified identity model — the sole source of ownership downstream."""

from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel


class VerifiedIdentity(BaseModel):
    """Safe identity fields extracted from a verified token.

    Only ``sub`` and ``role`` are carried forward; raw JWT claims are never exposed to
    handlers or responses. Ownership derives exclusively from ``sub``.
    """

    sub: UUID
    role: str | None = None
