"""Lazy, idempotent profile provisioning (U11 — see ADR 06).

FastAPI is the write and transaction owner, so provisioning is application orchestration,
not a database trigger. ``ensure_profile`` never opens, commits, or rolls back a
transaction: it runs on a connection the caller already has inside its own explicit
transaction, so provisioning either commits with that command or disappears with it.

Start-session (Phase 2 Step 3, not implemented in this branch) will call this inside the
one transaction it already opens, in this order::

    BEGIN
      reserve idempotency record
      ensure_profile(connection, user_id=actor.user_id)   <-- here
      read profile + revision snapshots
      INSERT session (created)
      UPDATE session -> active
      complete idempotency record
    COMMIT

The insert is ``ON CONFLICT DO NOTHING``. It creates database defaults for a first-time
user and is a no-op for everyone else; it can never overwrite an existing
``display_name`` or ``fretting_hand``. ``ON CONFLICT DO UPDATE`` is forbidden here.

``user_id`` is always the caller's ``AuthenticatedActor.user_id``, derived solely from the
verified JWT ``sub``. This module accepts no request DTO and no body-supplied identity.
"""

from __future__ import annotations

from uuid import UUID

import asyncpg
from pydantic import ValidationError

from app.domain.profiles import (
    ProfileIdentityNotFoundError,
    ProfileSnapshot,
    ProfileSnapshotUnavailableError,
)

INSERT_PROFILE_SQL = """
INSERT INTO public.profiles (user_id)
VALUES ($1)
ON CONFLICT (user_id) DO NOTHING
"""

SELECT_PROFILE_SQL = """
SELECT user_id, display_name, fretting_hand
FROM public.profiles
WHERE user_id = $1
"""


async def ensure_profile(
    connection: asyncpg.Connection,
    *,
    user_id: UUID,
) -> ProfileSnapshot:
    """Ensure a profile row exists for ``user_id`` and return its current snapshot.

    Runs inside the caller's transaction on the supplied connection. Existing profile
    values are never modified. Raises :class:`ProfileIdentityNotFoundError` if the user
    has no ``auth.users`` row, or :class:`ProfileSnapshotUnavailableError` if the row
    cannot be read back or fails the domain contract. Raw asyncpg exceptions from the
    provisioning path never escape this function.
    """
    try:
        await connection.execute(INSERT_PROFILE_SQL, user_id)
    except asyncpg.ForeignKeyViolationError as exc:
        raise ProfileIdentityNotFoundError(
            "no auth.users row exists for the authenticated subject"
        ) from exc

    record = await connection.fetchrow(SELECT_PROFILE_SQL, user_id)
    if record is None:
        raise ProfileSnapshotUnavailableError(
            "profile row was not readable after provisioning"
        )

    try:
        return ProfileSnapshot.model_validate(dict(record))
    except ValidationError as exc:
        raise ProfileSnapshotUnavailableError(
            "profile row did not satisfy the ProfileSnapshot contract"
        ) from exc
