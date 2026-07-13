"""The JWT verifier interface.

Verifiers raise :class:`~app.errors.AuthError` on any failure; they never build an HTTP
response themselves (the error handler owns 401 mapping + ``WWW-Authenticate``).
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from app.auth.models import VerifiedIdentity


@runtime_checkable
class JWTVerifier(Protocol):
    """Verifies a bearer token and returns a :class:`VerifiedIdentity`."""

    async def verify(self, token: str) -> VerifiedIdentity: ...
