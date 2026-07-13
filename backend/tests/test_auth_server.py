"""auth_server verifier unit tests (mocked Supabase Auth endpoint)."""

from __future__ import annotations

from uuid import UUID

import httpx
import pytest
from app.auth.auth_server_verifier import AuthServerVerifier
from app.errors import AuthError
from pytest_httpx import HTTPXMock

pytestmark = pytest.mark.asyncio

_BASE_URL = "http://auth.local"
_USER_URL = "http://auth.local/auth/v1/user"


def _verifier(client: httpx.AsyncClient) -> AuthServerVerifier:
    return AuthServerVerifier(base_url=_BASE_URL, publishable_key="pk_test", http_client=client)


async def test_accepts_valid_token(httpx_mock: HTTPXMock) -> None:
    sub = "22222222-2222-2222-2222-222222222222"
    httpx_mock.add_response(
        url=_USER_URL, json={"id": sub, "role": "authenticated"}, status_code=200
    )
    async with httpx.AsyncClient() as client:
        identity = await _verifier(client).verify("some-token")
    assert identity.sub == UUID(sub)
    assert identity.role == "authenticated"


async def test_rejects_when_auth_server_denies(httpx_mock: HTTPXMock) -> None:
    httpx_mock.add_response(url=_USER_URL, status_code=401)
    async with httpx.AsyncClient() as client:
        with pytest.raises(AuthError, match="rejected by auth server"):
            await _verifier(client).verify("bad-token")
