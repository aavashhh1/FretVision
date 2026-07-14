"""Live database verification of transactional sample-batch ingestion."""

from __future__ import annotations

import asyncio
import os
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import urlsplit

import asyncpg
import pytest
from app.commands.ingest_batch import IngestBatchHandler
from app.commands.start_session import StartSessionHandler
from app.db.database import Database
from app.domain.batches import IngestBatchCommand
from app.domain.sessions import StartSessionCommand
from app.errors import (
    IdempotencyConflictHttpError,
    SampleBatchConflictHttpError,
    SessionNotActiveHttpError,
    SessionNotFoundHttpError,
)

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
        pytest.skip(f"{env_var} not set; ingest-batch integration test requires it")
    host = (urlsplit(dsn).hostname or "").lower()
    if host not in _LOCAL_HOSTS:
        pytest.skip(f"{env_var} host {host!r} is not local; refusing remote mutation")
    return dsn


@asynccontextmanager
async def _fixture_user() -> AsyncIterator[tuple[uuid.UUID, Database]]:
    admin_dsn = _require_local_dsn("TEST_ADMIN_DATABASE_URL")
    app_dsn = _require_local_dsn("TEST_DATABASE_URL")
    user_id = uuid.uuid4()
    email = f"batch-{user_id.hex}@fretvision.invalid"

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


async def _start_active_session(*, user_id: uuid.UUID, database: Database) -> uuid.UUID:
    async with database.acquire() as connection:
        pair = await connection.fetchrow(_SELECT_PUBLISHED_PAIR_SQL)
    if pair is None:
        pytest.fail("local database has no published revision pair")
    start = StartSessionHandler(database=database, idempotency_ttl_seconds=86400)
    result = await start.execute(
        owner_id=user_id,
        idempotency_key=f"start-{uuid.uuid4()}",
        command=StartSessionCommand(
            exercise_revision_id=pair["exercise_revision_id"],
            target_position_revision_id=pair["target_position_revision_id"],
            declared_interval_ms=2500,
        ),
    )
    return result.response.session_id


def _batch(
    *,
    first_seq: int,
    sample_ids: tuple[uuid.UUID, ...],
    first_offset: int | None = None,
    accuracy: float = 0.8,
) -> IngestBatchCommand:
    offset = first_offset if first_offset is not None else (first_seq + 1) * 2500
    samples = [
        {
            "id": sample_id,
            "seq": first_seq + index,
            "is_valid": True,
            "placement_accuracy": accuracy,
            "confidence": 0.9,
            "interval_end_offset_ms": offset + index * 2500,
        }
        for index, sample_id in enumerate(sample_ids)
    ]
    return IngestBatchCommand.model_validate({"samples": samples})


async def test_batch_success_replay_and_hash_conflict_are_atomic() -> None:
    async with _fixture_user() as (user_id, database):
        session_id = await _start_active_session(user_id=user_id, database=database)
        handler = IngestBatchHandler(database=database, idempotency_ttl_seconds=86400)
        command = _batch(first_seq=0, sample_ids=(uuid.uuid4(), uuid.uuid4()))

        created = await handler.execute(
            owner_id=user_id,
            session_id=session_id,
            idempotency_key="integration-batch-1",
            command=command,
        )
        replayed = await handler.execute(
            owner_id=user_id,
            session_id=session_id,
            idempotency_key="integration-batch-1",
            command=command,
        )
        assert created == replayed
        assert created.response.accepted_count == 2

        conflicting = command.model_copy(
            update={
                "samples": tuple(
                    sample.model_copy(update={"placement_accuracy": 0.4})
                    for sample in command.samples
                )
            }
        )
        with pytest.raises(IdempotencyConflictHttpError):
            await handler.execute(
                owner_id=user_id,
                session_id=session_id,
                idempotency_key="integration-batch-1",
                command=conflicting,
            )

        async with database.acquire() as connection:
            sample_count = await connection.fetchval(
                "SELECT count(*) FROM public.session_samples WHERE session_id = $1",
                session_id,
            )
            stored = await connection.fetchrow(
                """
                SELECT state, session_id, response_status
                FROM public.idempotency_records
                WHERE user_id = $1 AND operation = 'ingest_batch'
                  AND idempotency_key = $2
                """,
                user_id,
                "integration-batch-1",
            )
        assert sample_count == 2
        assert stored is not None
        assert stored["state"] == "completed"
        assert stored["session_id"] == session_id
        assert stored["response_status"] == 200


async def test_concurrent_duplicate_serializes_to_one_batch() -> None:
    async with _fixture_user() as (user_id, database):
        session_id = await _start_active_session(user_id=user_id, database=database)
        handler = IngestBatchHandler(database=database, idempotency_ttl_seconds=86400)
        command = _batch(first_seq=0, sample_ids=(uuid.uuid4(),))

        first, second = await asyncio.gather(
            handler.execute(
                owner_id=user_id,
                session_id=session_id,
                idempotency_key="integration-batch-concurrent",
                command=command,
            ),
            handler.execute(
                owner_id=user_id,
                session_id=session_id,
                idempotency_key="integration-batch-concurrent",
                command=command,
            ),
        )
        assert first == second
        async with database.acquire() as connection:
            sample_count = await connection.fetchval(
                "SELECT count(*) FROM public.session_samples WHERE session_id = $1",
                session_id,
            )
        assert sample_count == 1


async def test_order_ownership_and_terminal_failures_roll_back_reservations() -> None:
    async with _fixture_user() as (owner_id, database):
        session_id = await _start_active_session(user_id=owner_id, database=database)
        owner_handler = IngestBatchHandler(database=database, idempotency_ttl_seconds=86400)

        with pytest.raises(SampleBatchConflictHttpError):
            await owner_handler.execute(
                owner_id=owner_id,
                session_id=session_id,
                idempotency_key="integration-batch-gap",
                command=_batch(first_seq=1, sample_ids=(uuid.uuid4(),)),
            )

        async with _fixture_user() as (other_id, other_database):
            other_handler = IngestBatchHandler(
                database=other_database,
                idempotency_ttl_seconds=86400,
            )
            with pytest.raises(SessionNotFoundHttpError):
                await other_handler.execute(
                    owner_id=other_id,
                    session_id=session_id,
                    idempotency_key="integration-batch-cross-user",
                    command=_batch(first_seq=0, sample_ids=(uuid.uuid4(),)),
                )

        async with database.transaction() as connection:
            await connection.execute(
                """
                UPDATE public.sessions
                SET lifecycle = 'abandoned', scoring_status = 'insufficient_coverage'
                WHERE id = $1 AND user_id = $2
                """,
                session_id,
                owner_id,
            )
        with pytest.raises(SessionNotActiveHttpError):
            await owner_handler.execute(
                owner_id=owner_id,
                session_id=session_id,
                idempotency_key="integration-batch-terminal",
                command=_batch(first_seq=0, sample_ids=(uuid.uuid4(),)),
            )

        async with database.acquire() as connection:
            batch_idem_count = await connection.fetchval(
                """
                SELECT count(*) FROM public.idempotency_records
                WHERE user_id = $1 AND operation = 'ingest_batch'
                """,
                owner_id,
            )
        assert batch_idem_count == 0


async def test_sample_identity_failure_rolls_back_new_batch_and_reservation() -> None:
    async with _fixture_user() as (user_id, database):
        session_id = await _start_active_session(user_id=user_id, database=database)
        handler = IngestBatchHandler(database=database, idempotency_ttl_seconds=86400)
        reused_id = uuid.uuid4()
        await handler.execute(
            owner_id=user_id,
            session_id=session_id,
            idempotency_key="integration-batch-original",
            command=_batch(first_seq=0, sample_ids=(reused_id,)),
        )

        with pytest.raises(SampleBatchConflictHttpError):
            await handler.execute(
                owner_id=user_id,
                session_id=session_id,
                idempotency_key="integration-batch-duplicate-id",
                command=_batch(first_seq=1, sample_ids=(reused_id,)),
            )

        async with database.acquire() as connection:
            sample_count = await connection.fetchval(
                "SELECT count(*) FROM public.session_samples WHERE session_id = $1",
                session_id,
            )
            failed_idem_count = await connection.fetchval(
                """
                SELECT count(*) FROM public.idempotency_records
                WHERE user_id = $1 AND operation = 'ingest_batch'
                  AND idempotency_key = 'integration-batch-duplicate-id'
                """,
                user_id,
            )
        assert sample_count == 1
        assert failed_idem_count == 0
