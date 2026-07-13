"""Signing-key resolution seam.

``PyJWKClient`` performs a synchronous network fetch of the JWK set, which cannot be
mocked by HTTP-transport fixtures and must not run on the event loop. Hiding it behind a
``SigningKeyProvider`` protocol lets production wrap the client (invoked via
``asyncio.to_thread``) while unit tests inject a fully in-memory fake — no real JWKS
network calls in unit tests.
"""

from __future__ import annotations

import asyncio
from typing import Any, Protocol

from jwt import PyJWKClient
from jwt.exceptions import PyJWKClientError


class SigningKeyError(Exception):
    """Raised when a signing key cannot be resolved for a token (e.g. unknown kid)."""


class SigningKeyProvider(Protocol):
    """Resolves the signing key material for a given JWT."""

    async def get_signing_key(self, token: str) -> Any: ...


class PyJWKClientSigningKeyProvider:
    """Production provider backed by one application-scoped ``PyJWKClient``.

    The client owns its own bounded JWK-set cache (``lifespan``) and HTTP timeout; the
    correct lookup API is ``get_signing_key_from_jwt``, run off the event loop via
    ``asyncio.to_thread``.
    """

    def __init__(self, jwks_url: str, *, cache_ttl_seconds: int, http_timeout: float) -> None:
        self._client = PyJWKClient(
            jwks_url,
            cache_keys=True,
            cache_jwk_set=True,
            lifespan=cache_ttl_seconds,
            timeout=http_timeout,
        )

    async def get_signing_key(self, token: str) -> Any:
        try:
            signing_key = await asyncio.to_thread(
                self._client.get_signing_key_from_jwt, token
            )
        except PyJWKClientError as exc:
            raise SigningKeyError(str(exc)) from exc
        return signing_key.key
