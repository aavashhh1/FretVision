"""User-ownership abstraction.

The only authoritative user identifier on the backend write path is the verified JWT
``sub``. The backend connects as ``fretvision_app`` (``BYPASSRLS``), so RLS provides no
protection here — ownership is an application-layer obligation. A request-body
``user_id`` / ``owner_id`` / ``profile_id`` (or any similar field) is never authoritative.

``AuthenticatedActor`` carries exactly one field, ``user_id``, derived solely from
``VerifiedIdentity.sub``. It intentionally excludes role, raw claims, and any token or
request data. Role is an authentication concern, not an ownership input.
"""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import Depends
from pydantic import BaseModel, ConfigDict

from app.auth.dependencies import require_identity
from app.auth.models import VerifiedIdentity


class AuthenticatedActor(BaseModel):
    """Immutable ownership identity. ``user_id`` is the sole authoritative owner."""

    model_config = ConfigDict(frozen=True)

    user_id: UUID

    @classmethod
    def from_identity(cls, identity: VerifiedIdentity) -> AuthenticatedActor:
        """Derive the actor from a verified identity's ``sub`` — and nothing else."""
        return cls(user_id=identity.sub)


_IdentityDep = Annotated[VerifiedIdentity, Depends(require_identity)]


async def require_actor(identity: _IdentityDep) -> AuthenticatedActor:
    """FastAPI dependency yielding the ownership actor from the verified identity."""
    return AuthenticatedActor.from_identity(identity)


ActorDep = Annotated[AuthenticatedActor, Depends(require_actor)]
