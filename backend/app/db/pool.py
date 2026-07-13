"""asyncpg connection-pool construction.

The pool is created with ``min_size`` defaulting to 0 (lazy) so process startup does
not require the database to be reachable — liveness stays green while readiness reports
the true state. ``application_name`` is set for observability.
"""

from __future__ import annotations

import asyncpg

from app.settings import Settings


async def create_pool(settings: Settings) -> asyncpg.Pool:
    """Create the application-scoped asyncpg pool."""
    return await asyncpg.create_pool(
        dsn=settings.database_url.get_secret_value(),
        min_size=settings.db_pool_min_size,
        max_size=settings.db_pool_max_size,
        command_timeout=settings.db_command_timeout,
        timeout=settings.db_connect_timeout,
        server_settings={"application_name": settings.db_application_name},
    )
