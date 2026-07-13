"""Profile domain model and provisioning errors.

Pure domain: no asyncpg, no FastAPI, no HTTP status codes. Provisioning failures are
raised as domain errors and mapped to HTTP responses by the command/API layer in Phase 2
Step 3 — nothing in this branch reaches a production route, so no mapping is decided here
(see ``docs/architecture/06-adr-profile-provisioning.md``).
"""

from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict

FrettingHand = Literal["left", "right"]


class ProfileSnapshot(BaseModel):
    """Immutable read-model of a user's profile at one point in a transaction.

    Output only. It is produced by the repository from a database row; it is never
    populated from a request body, and there is no inbound profile DTO.
    """

    model_config = ConfigDict(frozen=True)

    user_id: UUID
    display_name: str | None
    fretting_hand: FrettingHand


class ProfileProvisioningError(Exception):
    """Base domain error for profile provisioning failures."""


class ProfileIdentityNotFoundError(ProfileProvisioningError):
    """The user_id has no corresponding ``auth.users`` row.

    Raised when the profile insert violates the ``profiles.user_id`` foreign key — for
    example a still-valid JWT whose subject has since been deleted. The HTTP mapping is
    the command layer's decision, not the repository's.
    """


class ProfileSnapshotUnavailableError(ProfileProvisioningError):
    """The profile row could not be read back, or did not match the domain contract.

    Raised when the post-insert SELECT returns no row, or when the returned row fails
    ``ProfileSnapshot`` validation (e.g. an unexpected ``fretting_hand`` value). Both
    indicate an internal inconsistency, never a client error.
    """
