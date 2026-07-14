"""Application-scoped resource container.

Built during lifespan startup via an :class:`~contextlib.AsyncExitStack`: each resource
registers its own cleanup immediately after it is created, so a failure partway through
startup still tears down everything already opened, in reverse order. Stored on
``app.state``; there are no module-level resource globals.
"""

from __future__ import annotations

from contextlib import AsyncExitStack

import httpx

from app.auth.factory import build_verifier
from app.auth.verifier import JWTVerifier
from app.commands.ingest_batch import IngestBatchHandler
from app.commands.start_session import StartSessionHandler
from app.db.database import Database
from app.settings import Settings


class AppServices:
    def __init__(
        self,
        *,
        settings: Settings,
        http_client: httpx.AsyncClient,
        database: Database,
        verifier: JWTVerifier,
        start_session: StartSessionHandler,
        ingest_batch: IngestBatchHandler,
        stack: AsyncExitStack,
    ) -> None:
        self.settings = settings
        self.http_client = http_client
        self.database = database
        self.verifier = verifier
        self.start_session = start_session
        self.ingest_batch = ingest_batch
        self._stack = stack

    @classmethod
    async def create(cls, settings: Settings) -> AppServices:
        stack = AsyncExitStack()
        try:
            http_client = httpx.AsyncClient(timeout=httpx.Timeout(10.0))
            stack.push_async_callback(http_client.aclose)

            database = Database(settings)
            await database.open()
            stack.push_async_callback(database.close)

            verifier = build_verifier(settings, http_client)
            start_session = StartSessionHandler(
                database=database,
                idempotency_ttl_seconds=settings.idempotency_ttl_seconds,
            )
            ingest_batch = IngestBatchHandler(
                database=database,
                idempotency_ttl_seconds=settings.idempotency_ttl_seconds,
            )

            return cls(
                settings=settings,
                http_client=http_client,
                database=database,
                verifier=verifier,
                start_session=start_session,
                ingest_batch=ingest_batch,
                stack=stack,
            )
        except BaseException:
            # Reverse-order cleanup of whatever was already created.
            await stack.aclose()
            raise

    async def aclose(self) -> None:
        await self._stack.aclose()
