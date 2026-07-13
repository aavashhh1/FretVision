"""Error contract: envelope shape, status/header preservation, no leakage."""

from __future__ import annotations

from collections.abc import Callable

import pytest
from app.settings import Settings

pytestmark = pytest.mark.asyncio


async def test_auth_failure_is_401_with_challenge(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (_, client):  # type: ignore[attr-defined]
        response = await client.get("/me")
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    body = response.json()
    assert body["code"] == "unauthorized"
    assert body["request_id"]
    assert "claims" not in body


async def test_http_exception_status_preserved(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (_, client):  # type: ignore[attr-defined]
        response = await client.get("/does-not-exist")
    assert response.status_code == 404
    assert response.json()["code"] == "http_404"


async def test_validation_error_is_422(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (app, client):  # type: ignore[attr-defined]

        @app.get("/echo")
        async def echo(n: int) -> dict[str, int]:
            return {"n": n}

        response = await client.get("/echo", params={"n": "not-an-int"})
    assert response.status_code == 422
    body = response.json()
    assert body["code"] == "validation_error"
    assert isinstance(body["errors"], list)
