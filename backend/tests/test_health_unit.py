"""Health/readiness semantics without a live database."""

from __future__ import annotations

from collections.abc import Callable

import pytest
from app.errors import ReadinessError
from app.settings import Settings

pytestmark = pytest.mark.asyncio


async def test_healthz_ok_even_without_db(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (_, client):  # type: ignore[attr-defined]
        response = await client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_readyz_returns_503_on_failure(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (app, client):  # type: ignore[attr-defined]

        async def failing_check() -> None:
            raise ReadinessError()

        app.state.services.database.check_ready = failing_check
        response = await client.get("/readyz")
    assert response.status_code == 503
    assert response.json()["code"] == "not_ready"
