"""FastAPI auth dependency. Ownership derives exclusively from the verified ``sub``."""

from __future__ import annotations

from fastapi import Request

from app.auth.models import VerifiedIdentity
from app.errors import AuthError
from app.services import AppServices


async def require_identity(request: Request) -> VerifiedIdentity:
    """Extract and verify the bearer token, returning the verified identity.

    Raises :class:`AuthError` on any failure; the registered handler maps it to
    ``401`` with ``WWW-Authenticate: Bearer``. This dependency never reads a
    ``user_id`` from the request body.
    """
    services: AppServices = request.app.state.services
    header = request.headers.get("Authorization")
    if not header:
        raise AuthError("missing bearer token")

    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise AuthError("invalid authorization header")

    return await services.verifier.verify(token.strip())
