"""SQL repository for published revision snapshots and session activation."""

from __future__ import annotations

from uuid import UUID

import asyncpg
from pydantic import ValidationError

from app.domain.profiles import ProfileSnapshot
from app.domain.sessions import (
    RevisionPairUnavailableError,
    RevisionSnapshot,
    SessionSnapshotUnavailableError,
    StartSessionCommand,
    StartSessionResponse,
)

SELECT_REVISION_SNAPSHOT_SQL = """
SELECT er.id AS exercise_revision_id,
       tpr.id AS target_position_revision_id,
       er.accuracy_metric_version,
       er.calibration_method
FROM public.exercise_revisions AS er
JOIN public.target_position_revisions AS tpr
  ON tpr.exercise_revision_id = er.id
WHERE er.id = $1
  AND tpr.id = $2
  AND er.published = true
"""

INSERT_SESSION_CREATED_SQL = """
INSERT INTO public.sessions (
  user_id,
  exercise_revision_id,
  target_position_revision_id,
  fretting_hand_snapshot,
  accuracy_metric_version,
  calibration_method,
  declared_interval_ms
)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING id
"""

ACTIVATE_SESSION_SQL = """
UPDATE public.sessions
SET lifecycle = 'active',
    activated_at = now()
WHERE id = $1
  AND user_id = $2
  AND lifecycle = 'created'
RETURNING id AS session_id,
          lifecycle,
          exercise_revision_id,
          target_position_revision_id,
          declared_interval_ms,
          activated_at,
          fretting_hand_snapshot,
          accuracy_metric_version,
          calibration_method
"""


async def get_revision_snapshot(
    connection: asyncpg.Connection,
    *,
    exercise_revision_id: UUID,
    target_position_revision_id: UUID,
) -> RevisionSnapshot:
    record = await connection.fetchrow(
        SELECT_REVISION_SNAPSHOT_SQL,
        exercise_revision_id,
        target_position_revision_id,
    )
    if record is None:
        raise RevisionPairUnavailableError(
            "published exercise and target revision pair was not found"
        )
    try:
        return RevisionSnapshot.model_validate(dict(record))
    except ValidationError as exc:
        raise SessionSnapshotUnavailableError(
            "revision row did not satisfy the RevisionSnapshot contract"
        ) from exc


async def create_and_activate_session(
    connection: asyncpg.Connection,
    *,
    user_id: UUID,
    command: StartSessionCommand,
    profile: ProfileSnapshot,
    revision: RevisionSnapshot,
) -> StartSessionResponse:
    session_id = await connection.fetchval(
        INSERT_SESSION_CREATED_SQL,
        user_id,
        revision.exercise_revision_id,
        revision.target_position_revision_id,
        profile.fretting_hand,
        revision.accuracy_metric_version,
        revision.calibration_method,
        command.declared_interval_ms,
    )
    if session_id is None:
        raise SessionSnapshotUnavailableError("created session did not return an id")

    record = await connection.fetchrow(ACTIVATE_SESSION_SQL, session_id, user_id)
    if record is None:
        raise SessionSnapshotUnavailableError("created session could not transition to active")
    try:
        return StartSessionResponse.model_validate(dict(record))
    except ValidationError as exc:
        raise SessionSnapshotUnavailableError(
            "activated session did not satisfy the StartSessionResponse contract"
        ) from exc
