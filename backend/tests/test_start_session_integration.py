"""Live database verification of transactional start-session behavior.

The tests are double-gated by local-only app/admin DSNs. Admin access creates and
deletes only fresh auth.users fixtures; every application write uses fretvision_app.
"""

from __future__ import annotations

import asyncio
import os
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import urlsplit

import asyncpg
import pytest
from app.commands.start_session import StartSessionHandler
from app.db.database import Database
from app.domain.sessions import StartSessionCommand
from app.errors import IdempotencyConflictHttpError, SessionTargetNotFoundHttpError

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

_SELECT_PUBLISHED_PAIR_SQL = """
SELECT er.id AS exercise_revision_id, tpr.id AS target_position_revision_id
FROM public.exercise_revisions AS er
JOIN public.target_position_revisions AS tpr
  ON tpr.exercise_revision_id = er.id
WHERE er.published = true
ORDER BY er.id, tpr.id
LIMIT 1
"""


def _require_local_dsn(env_var: str) -> str:
    dsn = os.environ.get(env_var)
    if not dsn:
        pytest.skip(f"{env_var} not set; start-session integration test requires it")
    host = (urlsplit(dsn).hostname or "").lower()
    if host not in _LOCAL_HOSTS:
        pytest.skip(f"{env_var} host {host!r} is not local; refusing remote mutation")
    return dsn


@asynccontextmanager
async def _fixture_user() -> AsyncIterator[tuple[uuid.UUID, Database]]:
    admin_dsn = _require_local_dsn("TEST_ADMIN_DATABASE_URL")
    app_dsn = _require_local_dsn("TEST_DATABASE_URL")
    user_id = uuid.uuid4()
    email = f"start-{user_id.hex}@fretvision.invalid"

    admin = await asyncpg.connect(admin_dsn)
    try:
        await admin.execute(_INSERT_AUTH_USER_SQL, user_id, email)
        database = Database(build_settings(database_url=app_dsn))
        await database.open()
        try:
            yield user_id, database
        finally:
            await database.close()
    finally:
        await admin.execute(_DELETE_AUTH_USER_SQL, user_id)
        await admin.close()


async def _published_command(database: Database, *, interval_ms: int = 2500) -> StartSessionCommand:
    async with database.acquire() as connection:
        pair = await connection.fetchrow(_SELECT_PUBLISHED_PAIR_SQL)
    if pair is None:
        pytest.fail("local database has no published revision pair")
    return StartSessionCommand(
        exercise_revision_id=pair["exercise_revision_id"],
        target_position_revision_id=pair["target_position_revision_id"],
        declared_interval_ms=interval_ms,
    )


async def test_start_success_replay_and_conflict_are_atomic() -> None:
    async with _fixture_user() as (user_id, database):
        handler = StartSessionHandler(database=database, idempotency_ttl_seconds=86400)
        command = await _published_command(database)

        created = await handler.execute(
            owner_id=user_id,
            idempotency_key="integration-start-1",
            command=command,
        )
        replayed = await handler.execute(
            owner_id=user_id,
            idempotency_key="integration-start-1",
            command=command,
        )

        assert created == replayed
        assert created.response.lifecycle == "active"
        assert created.response.fretting_hand_snapshot == "left"

        with pytest.raises(IdempotencyConflictHttpError):
            await handler.execute(
                owner_id=user_id,
                idempotency_key="integration-start-1",
                command=command.model_copy(update={"declared_interval_ms": 3000}),
            )

        async with database.acquire() as connection:
            session_count = await connection.fetchval(
                "SELECT count(*) FROM public.sessions WHERE user_id = $1",
                user_id,
            )
            stored = await connection.fetchrow(
                """
                SELECT state, session_id, response_status
                FROM public.idempotency_records
                WHERE user_id = $1 AND operation = 'start_session'
                  AND idempotency_key = $2
                """,
                user_id,
                "integration-start-1",
            )

        assert session_count == 1
        assert stored is not None
        assert stored["state"] == "completed"
        assert stored["session_id"] == created.response.session_id
        assert stored["response_status"] == 201


async def test_concurrent_duplicate_serializes_to_one_session() -> None:
    async with _fixture_user() as (user_id, database):
        handler = StartSessionHandler(database=database, idempotency_ttl_seconds=86400)
        command = await _published_command(database)

        first, second = await asyncio.gather(
            handler.execute(
                owner_id=user_id,
                idempotency_key="integration-concurrent-1",
                command=command,
            ),
            handler.execute(
                owner_id=user_id,
                idempotency_key="integration-concurrent-1",
                command=command,
            ),
        )

        assert first == second
        async with database.acquire() as connection:
            session_count = await connection.fetchval(
                "SELECT count(*) FROM public.sessions WHERE user_id = $1",
                user_id,
            )
        assert session_count == 1


async def test_revision_failure_rolls_back_profile_and_reservation() -> None:
    async with _fixture_user() as (user_id, database):
        handler = StartSessionHandler(database=database, idempotency_ttl_seconds=86400)
        command = StartSessionCommand(
            exercise_revision_id=uuid.uuid4(),
            target_position_revision_id=uuid.uuid4(),
            declared_interval_ms=2500,
        )

        with pytest.raises(SessionTargetNotFoundHttpError):
            await handler.execute(
                owner_id=user_id,
                idempotency_key="integration-rollback-1",
                command=command,
            )

        async with database.acquire() as connection:
            profile_count = await connection.fetchval(
                "SELECT count(*) FROM public.profiles WHERE user_id = $1",
                user_id,
            )
            session_count = await connection.fetchval(
                "SELECT count(*) FROM public.sessions WHERE user_id = $1",
                user_id,
            )
            idem_count = await connection.fetchval(
                "SELECT count(*) FROM public.idempotency_records WHERE user_id = $1",
                user_id,
            )

        assert profile_count == 0
        assert session_count == 0
        assert idem_count == 0
