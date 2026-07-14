"""Shared test fixtures and helpers.

Unit tests never touch a live database or make real JWKS network calls: JWKS keys are
generated locally and injected via a fake ``SigningKeyProvider``, and the ASGI app is
driven through ``httpx.ASGITransport`` wrapped in ``LifespanManager`` (HTTPX does not
run FastAPI lifespan on its own). Lazy pools (``DB_POOL_MIN_SIZE=0``) mean startup does
not require a reachable database.
"""

from __future__ import annotations

import base64
import json
import time
import uuid
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from typing import Any

import httpx
import jwt
import pytest
from app.asgi_body_limit import RequestBodyLimitMiddleware
from app.asgi_request_id import RequestIdMiddleware
from app.auth.signing_keys import SigningKeyError
from app.main import create_app
from app.settings import Settings
from asgi_lifespan import LifespanManager
from cryptography.hazmat.primitives.asymmetric import ec

ISSUER = "https://issuer.test"
AUDIENCE = "authenticated"
KID = "test-key-1"

_LOCAL_DSN = "postgresql://user:supersecretpassword@127.0.0.1:54322/postgres"


# --------------------------------------------------------------------------- #
# Settings fixtures
# --------------------------------------------------------------------------- #
def build_settings(**overrides: Any) -> Settings:
    base: dict[str, Any] = {
        "_env_file": None,
        "app_env": "local",
        "database_url": _LOCAL_DSN,
        "db_connection_mode": "direct",
        "jwt_verification_mode": "auth_server",
        "supabase_url": "http://auth.local",
        "supabase_publishable_key": "pk_test_publishable",
    }
    base.update(overrides)
    return Settings(**base)


@pytest.fixture
def auth_server_settings() -> Settings:
    return build_settings()


@pytest.fixture
def jwks_settings() -> Settings:
    return build_settings(
        jwt_verification_mode="jwks",
        supabase_url=None,
        supabase_publishable_key=None,
        supabase_jwks_url="https://issuer.test/jwks.json",
        jwt_issuer=ISSUER,
        jwt_audience=AUDIENCE,
        jwt_allowed_algorithms="ES256",
    )


# --------------------------------------------------------------------------- #
# JWKS signing helpers
# --------------------------------------------------------------------------- #
@pytest.fixture
def signing_keypair() -> tuple[ec.EllipticCurvePrivateKey, ec.EllipticCurvePublicKey]:
    private_key = ec.generate_private_key(ec.SECP256R1())
    return private_key, private_key.public_key()


@pytest.fixture
def make_token(
    signing_keypair: tuple[ec.EllipticCurvePrivateKey, ec.EllipticCurvePublicKey],
) -> Callable[..., str]:
    private_key, _ = signing_keypair

    def _make(
        *,
        sub: str | None = None,
        include_sub: bool = True,
        iss: str | None = ISSUER,
        aud: str | None = AUDIENCE,
        exp_delta: int = 3600,
        role: str | None = "authenticated",
        kid: str | None = KID,
        alg: str = "ES256",
        key: ec.EllipticCurvePrivateKey | None = None,
    ) -> str:
        now = int(time.time())
        payload: dict[str, Any] = {"iat": now, "exp": now + exp_delta}
        if iss is not None:
            payload["iss"] = iss
        if aud is not None:
            payload["aud"] = aud
        if include_sub:
            payload["sub"] = sub if sub is not None else str(uuid.uuid4())
        if role is not None:
            payload["role"] = role
        headers = {"kid": kid} if kid is not None else {}
        return jwt.encode(payload, key or private_key, algorithm=alg, headers=headers)

    return _make


def raw_token(header: dict[str, Any], payload: dict[str, Any]) -> str:
    """Craft a token with arbitrary (possibly malformed) header/payload."""

    def _segment(data: dict[str, Any]) -> str:
        return base64.urlsafe_b64encode(json.dumps(data).encode()).rstrip(b"=").decode()

    return f"{_segment(header)}.{_segment(payload)}.c2ln"


class FakeSigningKeyProvider:
    """In-memory signing-key provider — no network."""

    def __init__(self, key: Any, *, raise_error: bool = False) -> None:
        self._key = key
        self._raise_error = raise_error

    async def get_signing_key(self, token: str) -> Any:
        if self._raise_error:
            raise SigningKeyError("no signing key for kid")
        return self._key


# --------------------------------------------------------------------------- #
# ASGI app / client helper
# --------------------------------------------------------------------------- #
@asynccontextmanager
async def make_app_client(
    settings: Settings,
) -> AsyncIterator[tuple[Any, httpx.AsyncClient]]:
    """Yield the FastAPI app (for state mutation) and an HTTP client bound to it."""
    fastapi_app = create_app(settings)
    asgi_app = RequestIdMiddleware(RequestBodyLimitMiddleware(fastapi_app))
    async with LifespanManager(asgi_app):
        transport = httpx.ASGITransport(app=asgi_app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            yield fastapi_app, client


@pytest.fixture
def app_client() -> Callable[[Settings], Any]:
    return make_app_client
