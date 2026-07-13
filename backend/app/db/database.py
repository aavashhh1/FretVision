"""The route-facing database abstraction.

Exposes exactly ``open``, ``close``, ``check_ready``, ``acquire``, and
``transaction``. It deliberately does **not** expose generic ``fetch``/``execute``
helpers: SQL is owned by repository modules in later steps, keeping raw queries out of
API handlers.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import asyncpg

from app.db.pool import create_pool
from app.errors import ReadinessError
from app.settings import Settings

logger = logging.getLogger("fretvision.db")


class Database:
    """Owns the asyncpg pool lifecycle and hands out connections/transactions."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._pool: asyncpg.Pool | None = None

    async def open(self) -> None:
        """Create the (lazy) connection pool. Does not require the DB to be up."""
        if self._pool is not None:
            return
        self._pool = await create_pool(self._settings)

    async def close(self) -> None:
        """Close the connection pool if open."""
        if self._pool is not None:
            await self._pool.close()
            self._pool = None

    def _require_pool(self) -> asyncpg.Pool:
        if self._pool is None:
            raise ReadinessError("database pool is not open")
        return self._pool

    def acquire(self) -> Any:
        """Return an async context manager yielding a pooled connection."""
        return self._require_pool().acquire()

    @asynccontextmanager
    async def transaction(self) -> AsyncIterator[asyncpg.Connection]:
        """Acquire a connection and run the body inside an explicit transaction."""
        pool = self._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                yield connection

    async def check_ready(self) -> None:
        """Acquire a connection and run ``SELECT 1``; raise ReadinessError on failure."""
        try:
            async with self.acquire() as connection:
                await connection.execute("SELECT 1")
        except ReadinessError:
            raise
        except Exception as exc:  # noqa: BLE001 - converted to a controlled 503
            logger.warning("readiness_check_failed", extra={"error_type": type(exc).__name__})
            raise ReadinessError() from exc
