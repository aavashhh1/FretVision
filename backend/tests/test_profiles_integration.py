"""Live-database proof that ``fretvision_app`` can provision and read a profile.

Double-gated: skipped unless BOTH ``TEST_DATABASE_URL`` (the ``fretvision_app`` role, used
for all provisioning and profile reads/writes) and ``TEST_ADMIN_DATABASE_URL`` (an admin
role, used ONLY to create and delete the ``auth.users`` fixture row, which the app role has
no privilege to touch) are set. The default ``uv run pytest`` never runs it.

Both DSNs must point at a local database; a non-local host is skipped rather than mutated,
so a stray hosted DSN cannot be written to by accident. The fixture user is a fresh UUID
and e-mail per run, and is deleted in ``finally`` (cascading the profile away). No catalog
or seed row is read, written, or reset.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import urlsplit

import asyncpg
import pytest
from app.db.database import Database
from app.domain.profiles import ProfileSnapshot
from app.repositories.profiles import ensure_profile

from tests.conftest import build_settings

pytestmark = [pytest.mark.integration, pytest.mark.asyncio]

_LOCAL_HOSTS = frozenset({"localhost", "127.0.0.1", "::1", ""})

_INSERT_AUTH_USER_SQL = """
INSERT INTO auth.users (id, instance_id, aud, role, email,
                        encrypted_password, created_at, updated_at)
VALUES ($1, '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', $2, '', now(), now())
"""

_DELETE_AUTH_USER_SQL = "DELETE FROM auth.users WHERE id = $1"

_SELECT_CREATED_AT_SQL = "SELECT created_at FROM public.profiles WHERE user_id = $1"

_UPDATE_PROFILE_SQL = """
UPDATE public.profiles
SET display_name = $2, fretting_hand = $3
WHERE user_id = $1
"""


def _require_local_dsn(env_var: str) -> str:
    dsn = os.environ.get(env_var)
    if not dsn:
        pytest.skip(f"{env_var} not set; profile provisioning integration test requires it")
    host = (urlsplit(dsn).hostname or "").lower()
    if host not in _LOCAL_HOSTS:
        pytest.skip(f"{env_var} host {host!r} is not local; refusing to mutate a remote database")
    return dsn


@asynccontextmanager
async def _fixture_user() -> AsyncIterator[tuple[uuid.UUID, Database]]:
    """Create one auth.users row as admin; yield it with an app-role Database."""
    admin_dsn = _require_local_dsn("TEST_ADMIN_DATABASE_URL")
    app_dsn = _require_local_dsn("TEST_DATABASE_URL")

    user_id = uuid.uuid4()
    email = f"u11-{user_id.hex}@fretvision.invalid"

    admin: asyncpg.Connection = await asyncpg.connect(admin_dsn)
    try:
        await admin.execute(_INSERT_AUTH_USER_SQL, user_id, email)

        database = Database(build_settings(database_url=app_dsn))
        await database.open()
        try:
            yield user_id, database
        finally:
            await database.close()
    finally:
        # Cascades to public.profiles, so no profile row is left behind either.
        await admin.execute(_DELETE_AUTH_USER_SQL, user_id)
        await admin.close()


async def test_app_role_provisions_and_reads_profile_without_overwriting() -> None:
    async with _fixture_user() as (user_id, database):
        # --- First provisioning: the row does not exist yet. Defaults are created. ---
        async with database.transaction() as connection:
            created = await ensure_profile(connection, user_id=user_id)

        assert created == ProfileSnapshot(
            user_id=user_id, display_name=None, fretting_hand="left"
        )

        # --- The user edits their profile (as the app role would on a future route). ---
        async with database.transaction() as connection:
            await connection.execute(_UPDATE_PROFILE_SQL, user_id, "Existing Name", "right")
            created_at_before: Any = await connection.fetchval(_SELECT_CREATED_AT_SQL, user_id)

        # --- Second provisioning: must be a no-op, not an upsert. ---
        async with database.transaction() as connection:
            reprovisioned = await ensure_profile(connection, user_id=user_id)

        assert reprovisioned == ProfileSnapshot(
            user_id=user_id, display_name="Existing Name", fretting_hand="right"
        )

        # Read the stored row again: nothing was overwritten, and the row was not
        # replaced (created_at is queried directly, before and after).
        async with database.transaction() as connection:
            created_at_after: Any = await connection.fetchval(_SELECT_CREATED_AT_SQL, user_id)
            stored = await connection.fetchrow(
                "SELECT display_name, fretting_hand FROM public.profiles WHERE user_id = $1",
                user_id,
            )

        assert created_at_after == created_at_before
        assert stored is not None
        assert stored["display_name"] == "Existing Name"
        assert stored["fretting_hand"] == "right"
