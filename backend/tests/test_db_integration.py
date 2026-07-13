"""Live-database tests. Gated behind ``-m integration`` and TEST_DATABASE_URL.

These use only a session-local temporary table (dropped explicitly): they never
mutate seed/catalog rows, truncate tables, reset Supabase, or leave rows behind.
"""

from __future__ import annotations

import os

import pytest
from app.db.database import Database
from app.errors import ReadinessError

from tests.conftest import build_settings, make_app_client

pytestmark = [pytest.mark.integration, pytest.mark.asyncio]


def _test_dsn() -> str:
    dsn = os.environ.get("TEST_DATABASE_URL")
    if not dsn:
        pytest.skip("TEST_DATABASE_URL not set; integration tests require it")
    return dsn


async def test_pool_open_check_close() -> None:
    database = Database(build_settings(database_url=_test_dsn()))
    await database.open()
    try:
        await database.check_ready()  # succeeds against a live DB
    finally:
        await database.close()
    # After close the pool is gone; readiness must fail cleanly.
    with pytest.raises(ReadinessError):
        await database.check_ready()


async def test_check_ready_failure_on_unreachable_db() -> None:
    database = Database(build_settings(database_url="postgresql://u:p@127.0.0.1:1/postgres"))
    await database.open()  # lazy pool: does not connect yet
    try:
        with pytest.raises(ReadinessError):
            await database.check_ready()
    finally:
        await database.close()


async def test_transaction_commit_and_rollback() -> None:
    database = Database(build_settings(database_url=_test_dsn()))
    await database.open()
    try:
        async with database.acquire() as conn:
            await conn.execute("CREATE TEMP TABLE _fv_tx_test (val int)")
            try:
                # Rollback path.
                tx = conn.transaction()
                await tx.start()
                await conn.execute("INSERT INTO _fv_tx_test (val) VALUES (1)")
                await tx.rollback()
                assert await conn.fetchval("SELECT count(*) FROM _fv_tx_test") == 0

                # Commit path.
                tx = conn.transaction()
                await tx.start()
                await conn.execute("INSERT INTO _fv_tx_test (val) VALUES (2)")
                await tx.commit()
                assert await conn.fetchval("SELECT count(*) FROM _fv_tx_test") == 1
            finally:
                await conn.execute("DROP TABLE IF EXISTS _fv_tx_test")

        # The Database.transaction() context manager commits a successful body.
        async with database.transaction() as conn:
            assert await conn.fetchval("SELECT 1") == 1
    finally:
        await database.close()


async def test_readyz_smoke_against_local_db() -> None:
    settings = build_settings(database_url=_test_dsn())
    async with make_app_client(settings) as (_, client):
        response = await client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
