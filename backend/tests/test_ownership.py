"""Ownership derives solely from the verified JWT ``sub``.

The malicious-body test drives the real ``require_actor`` dependency and the real
route/service convention (identity passed separately from the payload), stubbing only
the token->identity boundary through FastAPI's supported ``dependency_overrides`` seam.
No live database and no production-only test hook are involved.
"""

from __future__ import annotations

from collections.abc import Callable
from uuid import UUID

import pytest
from app.auth.dependencies import require_identity
from app.auth.models import VerifiedIdentity
from app.auth.ownership import ActorDep, AuthenticatedActor
from app.settings import Settings
from fastapi import APIRouter
from pydantic import BaseModel, ConfigDict, ValidationError

# asyncio_mode="auto" runs async tests without a marker; sync unit tests stay sync.

USER_A = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_B = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"


class SampleCommand(BaseModel):
    # Test-only: prove that even an *accepted* body ``user_id`` is dropped and cannot
    # influence ownership. This is not a global rule for production command DTOs.
    model_config = ConfigDict(extra="ignore")

    note: str = ""


class SpyService:
    """Records exactly what the route hands it."""

    def __init__(self) -> None:
        self.calls: list[tuple[UUID, SampleCommand]] = []

    async def execute(self, *, owner_id: UUID, command: SampleCommand) -> None:
        self.calls.append((owner_id, command))


def _command_router(service: SpyService) -> APIRouter:
    router = APIRouter()

    @router.post("/_test/commands")
    async def run_command(actor: ActorDep, command: SampleCommand) -> dict[str, str]:
        # Identity is kept strictly separate from the payload; the authoritative owner
        # comes from the verified actor, never from the request body.
        await service.execute(owner_id=actor.user_id, command=command)
        return {"owner_id": str(actor.user_id)}

    return router


# --------------------------------------------------------------------------- #
# Pure-unit tests (no app)
# --------------------------------------------------------------------------- #
def test_from_identity_uses_sub() -> None:
    identity = VerifiedIdentity(sub=UUID(USER_A), role="admin")
    actor = AuthenticatedActor.from_identity(identity)
    assert actor.user_id == UUID(USER_A)


def test_actor_holds_only_user_id() -> None:
    # No role, no raw claims, no aliases — ownership only.
    assert set(AuthenticatedActor.model_fields) == {"user_id"}


def test_actor_is_immutable() -> None:
    actor = AuthenticatedActor(user_id=UUID(USER_A))
    with pytest.raises(ValidationError):
        actor.user_id = UUID(USER_B)  # type: ignore[misc]


# --------------------------------------------------------------------------- #
# Dependency-enforcement tests (real app, test-only router)
# --------------------------------------------------------------------------- #
async def test_missing_bearer_is_401(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (app, client):  # type: ignore[attr-defined]
        app.include_router(_command_router(SpyService()))
        response = await client.post("/_test/commands", json={"note": "x"})
    assert response.status_code == 401


async def test_invalid_token_is_401(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (app, client):  # type: ignore[attr-defined]
        app.include_router(_command_router(SpyService()))
        response = await client.post(
            "/_test/commands", json={"note": "x"}, headers={"Authorization": "Basic abc"}
        )
    assert response.status_code == 401


async def test_body_user_id_cannot_override_ownership(
    app_client: Callable[[Settings], object], auth_server_settings: Settings
) -> None:
    spy = SpyService()

    async with app_client(auth_server_settings) as (app, client):  # type: ignore[attr-defined]
        app.include_router(_command_router(spy))
        # Stub the token->identity boundary AFTER startup via the supported seam.
        # Token subject is User A; the real require_actor runs on top of this.
        app.dependency_overrides[require_identity] = lambda: VerifiedIdentity(
            sub=UUID(USER_A), role="admin"
        )

        response = await client.post(
            "/_test/commands",
            headers={"Authorization": "Bearer any-token"},
            json={"user_id": USER_B, "role": "admin", "note": "x"},
        )

    # The service received User A, never User B.
    assert response.status_code == 200
    assert response.json() == {"owner_id": USER_A}
    assert len(spy.calls) == 1
    owner_id, command = spy.calls[0]
    assert owner_id == UUID(USER_A)

    # User B never became owner, command field, or response value.
    assert not hasattr(command, "user_id")
    assert command.model_dump() == {"note": "x"}
    assert USER_B not in response.text

    # Raw claims never reach the service; the actor exposes only user_id.
    assert set(AuthenticatedActor.model_fields) == {"user_id"}
