"""Transactional sample-batch ingestion command handler."""

from __future__ import annotations

from typing import NoReturn
from uuid import UUID

from pydantic import ValidationError

from app.db.database import Database
from app.domain.batches import (
    BatchPersistenceError,
    BatchSessionNotActiveError,
    BatchSessionUnavailableError,
    IngestBatchCommand,
    IngestBatchExecutionResult,
    IngestBatchResponse,
    SampleIdentityConflictError,
    SampleSequenceConflictError,
)
from app.domain.idempotency import (
    AuthenticatedSubjectNotFoundError,
    IdempotencyKeyConflictError,
    IdempotencyRecordUnavailableError,
    IdempotencyReplay,
)
from app.errors import (
    AuthError,
    IdempotencyConflictHttpError,
    SampleBatchConflictHttpError,
    SessionNotActiveHttpError,
    SessionNotFoundHttpError,
)
from app.repositories.batches import append_sample_batch, lock_owned_active_session
from app.repositories.idempotency import complete_ingest_batch, reserve_ingest_batch

INGEST_BATCH_STATUS = 200


class _ReplayRollback(Exception):
    def __init__(self, replay: IdempotencyReplay) -> None:
        self.replay = replay
        super().__init__("roll back read-only ingest-batch replay transaction")


class IngestBatchHandler:
    def __init__(self, *, database: Database, idempotency_ttl_seconds: int) -> None:
        self._database = database
        self._idempotency_ttl_seconds = idempotency_ttl_seconds

    async def execute(
        self,
        *,
        owner_id: UUID,
        session_id: UUID,
        idempotency_key: str,
        command: IngestBatchCommand,
    ) -> IngestBatchExecutionResult:
        try:
            async with self._database.transaction() as connection:
                resolution = await reserve_ingest_batch(
                    connection,
                    user_id=owner_id,
                    idempotency_key=idempotency_key,
                    request_hash=command.request_hash(session_id=session_id),
                    ttl_seconds=self._idempotency_ttl_seconds,
                )
                if isinstance(resolution, IdempotencyReplay):
                    raise _ReplayRollback(resolution)

                session = await lock_owned_active_session(
                    connection,
                    session_id=session_id,
                    user_id=owner_id,
                )
                await append_sample_batch(
                    connection,
                    session=session,
                    command=command,
                )
                response = IngestBatchResponse(
                    session_id=session_id,
                    accepted_count=len(command.samples),
                    first_seq=command.samples[0].seq,
                    last_seq=command.samples[-1].seq,
                )
                await complete_ingest_batch(
                    connection,
                    record_id=resolution.record_id,
                    session_id=session_id,
                    response_status=INGEST_BATCH_STATUS,
                    response_body=response.model_dump(mode="json"),
                )
                return IngestBatchExecutionResult(
                    response_status=INGEST_BATCH_STATUS,
                    response=response,
                )
        except _ReplayRollback as exc:
            return self._replay_result(exc.replay)
        except IdempotencyKeyConflictError as exc:
            raise IdempotencyConflictHttpError() from exc
        except BatchSessionUnavailableError as exc:
            raise SessionNotFoundHttpError() from exc
        except BatchSessionNotActiveError as exc:
            raise SessionNotActiveHttpError() from exc
        except (SampleSequenceConflictError, SampleIdentityConflictError) as exc:
            raise SampleBatchConflictHttpError(str(exc)) from exc
        except AuthenticatedSubjectNotFoundError as exc:
            raise AuthError("authenticated subject no longer exists") from exc
        except (IdempotencyRecordUnavailableError, BatchPersistenceError) as exc:
            self._raise_internal(exc)

    @staticmethod
    def _replay_result(replay: IdempotencyReplay) -> IngestBatchExecutionResult:
        if replay.response_status != INGEST_BATCH_STATUS:
            raise RuntimeError("stored ingest-batch response has an unexpected status")
        try:
            response = IngestBatchResponse.model_validate(replay.response_body)
            return IngestBatchExecutionResult(
                response_status=replay.response_status,
                response=response,
            )
        except ValidationError as exc:
            raise RuntimeError("stored ingest-batch response failed its domain contract") from exc

    @staticmethod
    def _raise_internal(exc: Exception) -> NoReturn:
        raise RuntimeError("ingest-batch persistence contract failed") from exc
