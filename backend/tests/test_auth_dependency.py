"""Protected /me route: enforcement and ownership-from-sub."""

from __future__ import annotations

from collections.abc import Callable
from uuid import UUID

import pytest
from app.auth.models import VerifiedIdentity
from app.settings import Settings

pytestmark = pytest.mark.asyncio

_SUB = "33333333-3333-3333-3333-333333333333"


class StubVerifier:
    """Returns a fixed identity, ignoring the token entirely."""

    async def verify(self, token: str) -> VerifiedIdentity:
        return VerifiedIdentity(sub=UUID(_SUB), role="authenticated")


async def test_me_requires_bearer(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (_, client):  # type: ignore[attr-defined]
        response = await client.get("/me")
    assert response.status_code == 401


async def test_me_rejects_malformed_header(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (_, client):  # type: ignore[attr-defined]
        response = await client.get("/me", headers={"Authorization": "Basic abc"})
    assert response.status_code == 401


async def test_me_returns_only_safe_identity(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (app, client):  # type: ignore[attr-defined]
        app.state.services.verifier = StubVerifier()
        response = await client.get("/me", headers={"Authorization": "Bearer any-token"})
    assert response.status_code == 200
    body = response.json()
    # Ownership derives from the verified sub; only safe fields are returned.
    assert body == {"sub": _SUB, "role": "authenticated"}
