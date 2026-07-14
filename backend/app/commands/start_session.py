"""Transactional start-session command handler."""

from __future__ import annotations

from typing import NoReturn
from uuid import UUID

from pydantic import ValidationError

from app.db.database import Database
from app.domain.idempotency import (
    AuthenticatedSubjectNotFoundError,
    IdempotencyKeyConflictError,
    IdempotencyRecordUnavailableError,
    IdempotencyReplay,
)
from app.domain.profiles import (
    ProfileIdentityNotFoundError,
    ProfileSnapshotUnavailableError,
)
from app.domain.sessions import (
    RevisionPairUnavailableError,
    SessionSnapshotUnavailableError,
    StartSessionCommand,
    StartSessionExecutionResult,
    StartSessionResponse,
)
from app.errors import (
    AuthError,
    IdempotencyConflictHttpError,
    SessionTargetNotFoundHttpError,
)
from app.repositories.idempotency import (
    complete_start_session,
    reserve_start_session,
)
from app.repositories.profiles import ensure_profile
from app.repositories.sessions import create_and_activate_session, get_revision_snapshot

START_SESSION_STATUS = 201


class _ReplayRollback(Exception):
    """Internal control flow that forces transaction rollback before replay return."""

    def __init__(self, replay: IdempotencyReplay) -> None:
        self.replay = replay
        super().__init__("roll back read-only replay transaction")


class StartSessionHandler:
    def __init__(self, *, database: Database, idempotency_ttl_seconds: int) -> None:
        self._database = database
        self._idempotency_ttl_seconds = idempotency_ttl_seconds

    async def execute(
        self,
        *,
        owner_id: UUID,
        idempotency_key: str,
        command: StartSessionCommand,
    ) -> StartSessionExecutionResult:
        """Execute start-session atomically, including idempotency orchestration."""
        try:
            async with self._database.transaction() as connection:
                resolution = await reserve_start_session(
                    connection,
                    user_id=owner_id,
                    idempotency_key=idempotency_key,
                    request_hash=command.request_hash(),
                    ttl_seconds=self._idempotency_ttl_seconds,
                )
                if isinstance(resolution, IdempotencyReplay):
                    raise _ReplayRollback(resolution)

                profile = await ensure_profile(connection, user_id=owner_id)
                revision = await get_revision_snapshot(
                    connection,
                    exercise_revision_id=command.exercise_revision_id,
                    target_position_revision_id=command.target_position_revision_id,
                )
                response = await create_and_activate_session(
                    connection,
                    user_id=owner_id,
                    command=command,
                    profile=profile,
                    revision=revision,
                )
                response_body = response.model_dump(mode="json")
                await complete_start_session(
                    connection,
                    record_id=resolution.record_id,
                    session_id=response.session_id,
                    response_status=START_SESSION_STATUS,
                    response_body=response_body,
                )
                return StartSessionExecutionResult(
                    response_status=START_SESSION_STATUS,
                    response=response,
                )
        except _ReplayRollback as exc:
            return self._replay_result(exc.replay)
        except IdempotencyKeyConflictError as exc:
            raise IdempotencyConflictHttpError() from exc
        except RevisionPairUnavailableError as exc:
            raise SessionTargetNotFoundHttpError() from exc
        except (
            AuthenticatedSubjectNotFoundError,
            ProfileIdentityNotFoundError,
        ) as exc:
            raise AuthError("authenticated subject no longer exists") from exc
        except (
            IdempotencyRecordUnavailableError,
            ProfileSnapshotUnavailableError,
            SessionSnapshotUnavailableError,
        ) as exc:
            self._raise_internal(exc)

    @staticmethod
    def _replay_result(replay: IdempotencyReplay) -> StartSessionExecutionResult:
        if replay.response_status != START_SESSION_STATUS:
            raise RuntimeError("stored start-session response has an unexpected status")
        try:
            response = StartSessionResponse.model_validate(replay.response_body)
            return StartSessionExecutionResult(
                response_status=replay.response_status,
                response=response,
            )
        except ValidationError as exc:
            raise RuntimeError("stored start-session response failed its domain contract") from exc

    @staticmethod
    def _raise_internal(exc: Exception) -> NoReturn:
        raise RuntimeError("start-session persistence contract failed") from exc
