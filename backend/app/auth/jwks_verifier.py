"""JWKS verifier — the required hosted/production mode.

Header pre-checks reject a missing ``kid``, a missing ``alg``, or any algorithm outside
the configured asymmetric allowlist before verification. The signing key is resolved via
an injected :class:`SigningKeyProvider`, then the token is verified for signature,
``exp``, ``nbf`` (when present), issuer, audience, and a non-empty UUID ``sub``. There is
no fallback to ``auth_server`` on failure.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

import jwt
from jwt import (
    ExpiredSignatureError,
    ImmatureSignatureError,
    InvalidAudienceError,
    InvalidIssuerError,
    InvalidSignatureError,
    PyJWTError,
)

from app.auth.models import VerifiedIdentity
from app.auth.signing_keys import SigningKeyError, SigningKeyProvider
from app.errors import AuthError


class JwksVerifier:
    def __init__(
        self,
        *,
        provider: SigningKeyProvider,
        issuer: str,
        audience: str,
        allowed_algorithms: frozenset[str],
    ) -> None:
        self._provider = provider
        self._issuer = issuer
        self._audience = audience
        self._allowed_algorithms = allowed_algorithms

    async def verify(self, token: str) -> VerifiedIdentity:
        header = self._parse_header(token)
        self._check_header(header)

        try:
            key = await self._provider.get_signing_key(token)
        except SigningKeyError as exc:
            raise AuthError("unknown signing key") from exc

        claims = self._decode(token, key)
        return self._identity_from_claims(claims)

    def _parse_header(self, token: str) -> dict[str, object]:
        try:
            return jwt.get_unverified_header(token)
        except PyJWTError as exc:
            raise AuthError("malformed token header") from exc

    def _check_header(self, header: dict[str, object]) -> None:
        if not header.get("kid"):
            raise AuthError("token missing kid")
        alg = header.get("alg")
        if not alg:
            raise AuthError("token missing alg")
        if alg not in self._allowed_algorithms:
            raise AuthError("token algorithm not allowed")

    def _decode(self, token: str, key: Any) -> dict[str, object]:
        try:
            return jwt.decode(
                token,
                key,
                algorithms=list(self._allowed_algorithms),
                audience=self._audience,
                issuer=self._issuer,
                options={"require": ["exp", "sub"]},
            )
        except ExpiredSignatureError as exc:
            raise AuthError("token expired") from exc
        except ImmatureSignatureError as exc:
            raise AuthError("token not yet valid") from exc
        except InvalidAudienceError as exc:
            raise AuthError("invalid audience") from exc
        except InvalidIssuerError as exc:
            raise AuthError("invalid issuer") from exc
        except InvalidSignatureError as exc:
            raise AuthError("invalid signature") from exc
        except PyJWTError as exc:
            raise AuthError("invalid token") from exc

    def _identity_from_claims(self, claims: dict[str, object]) -> VerifiedIdentity:
        sub = claims.get("sub")
        if not isinstance(sub, str) or not sub.strip():
            raise AuthError("token missing sub")
        try:
            sub_uuid = UUID(sub)
        except ValueError as exc:
            raise AuthError("token sub is not a valid UUID") from exc
        role = claims.get("role")
        return VerifiedIdentity(sub=sub_uuid, role=role if isinstance(role, str) else None)
