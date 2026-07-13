"""Request-id middleware behavior."""

from __future__ import annotations

from collections.abc import Callable
from uuid import UUID

import pytest
from app.settings import Settings

pytestmark = pytest.mark.asyncio


async def test_generates_uuid_when_missing(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (_, client):  # type: ignore[attr-defined]
        response = await client.get("/healthz")
    request_id = response.headers["x-request-id"]
    # Valid UUID => generated.
    UUID(request_id)


async def test_echoes_valid_request_id(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (_, client):  # type: ignore[attr-defined]
        response = await client.get("/healthz", headers={"X-Request-ID": "trace-abc_123"})
    assert response.headers["x-request-id"] == "trace-abc_123"


async def test_replaces_unsafe_request_id(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    unsafe = "bad id with spaces and !!"
    async with app_client(auth_server_settings) as (_, client):  # type: ignore[attr-defined]
        response = await client.get("/healthz", headers={"X-Request-ID": unsafe})
    request_id = response.headers["x-request-id"]
    assert request_id != unsafe
    UUID(request_id)  # replaced with a generated UUID
