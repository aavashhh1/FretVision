"""A minimal protected route demonstrating verifier enforcement."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends

from app.auth.dependencies import require_identity
from app.auth.models import VerifiedIdentity

router = APIRouter(tags=["identity"])

Identity = Annotated[VerifiedIdentity, Depends(require_identity)]


@router.get("/me", response_model=VerifiedIdentity)
async def me(identity: Identity) -> VerifiedIdentity:
    """Return only safe identity fields (never raw JWT claims)."""
    return identity
