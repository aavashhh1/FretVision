"""HTTP contract tests for authenticated start-session requests."""

from __future__ import annotations

from collections.abc import AsyncIterator, Callable
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from app.auth.dependencies import require_identity
from app.auth.models import VerifiedIdentity
from app.domain.sessions import (
    StartSessionCommand,
    StartSessionExecutionResult,
    StartSessionResponse,
)
from app.settings import Settings

USER_A = UUID("aaaaaaaa-0000-4000-8000-000000000001")
USER_B = UUID("bbbbbbbb-0000-4000-8000-000000000002")
EXERCISE_ID = UUID("cccccccc-0000-4000-8000-000000000003")
TARGET_ID = UUID("dddddddd-0000-4000-8000-000000000004")
SESSION_ID = UUID("eeeeeeee-0000-4000-8000-000000000005")


class SpyStartSessionHandler:
    def __init__(self) -> None:
        self.calls: list[tuple[UUID, str, StartSessionCommand]] = []

    async def execute(
        self,
        *,
        owner_id: UUID,
        idempotency_key: str,
        command: StartSessionCommand,
    ) -> StartSessionExecutionResult:
        self.calls.append((owner_id, idempotency_key, command))
        return StartSessionExecutionResult(
            response_status=201,
            response=StartSessionResponse(
                session_id=SESSION_ID,
                lifecycle="active",
                exercise_revision_id=EXERCISE_ID,
                target_position_revision_id=TARGET_ID,
                declared_interval_ms=command.declared_interval_ms,
                activated_at=datetime(2026, 7, 14, 12, 0, tzinfo=UTC),
                fretting_hand_snapshot="left",
                accuracy_metric_version=1,
                calibration_method="manual_4pt",
            ),
        )


async def test_route_uses_actor_and_ignores_body_owned_fields(
    app_client: Callable[[Settings], Any], auth_server_settings: Settings
) -> None:
    spy = SpyStartSessionHandler()
    async with app_client(auth_server_settings) as (app, client):
        app.state.services.start_session = spy
        app.dependency_overrides[require_identity] = lambda: VerifiedIdentity(
            sub=USER_A,
            role="authenticated",
        )
        response = await client.post(
            "/sessions",
            headers={
                "Authorization": "Bearer test-token",
                "Idempotency-Key": "start-key-1",
            },
            json={
                "exercise_revision_id": str(EXERCISE_ID),
                "target_position_revision_id": str(TARGET_ID),
                "declared_interval_ms": 2500,
                "user_id": str(USER_B),
                "fretting_hand_snapshot": "right",
                "accuracy_metric_version": 999,
            },
        )

    assert response.status_code == 201
    assert response.json()["session_id"] == str(SESSION_ID)
    assert len(spy.calls) == 1
    owner_id, key, command = spy.calls[0]
    assert owner_id == USER_A
    assert key == "start-key-1"
    assert set(command.model_fields_set) == {
        "exercise_revision_id",
        "target_position_revision_id",
        "declared_interval_ms",
    }


async def test_route_requires_valid_idempotency_key(
    app_client: Callable[[Settings], Any], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (app, client):
        app.dependency_overrides[require_identity] = lambda: VerifiedIdentity(
            sub=USER_A,
            role="authenticated",
        )
        response = await client.post(
            "/sessions",
            headers={"Authorization": "Bearer test-token", "Idempotency-Key": "short"},
            json={
                "exercise_revision_id": str(EXERCISE_ID),
                "target_position_revision_id": str(TARGET_ID),
                "declared_interval_ms": 2500,
            },
        )

    assert response.status_code == 422
    assert response.json()["code"] == "validation_error"


async def test_request_body_over_64_kib_is_413(
    app_client: Callable[[Settings], Any], auth_server_settings: Settings
) -> None:
    async with app_client(auth_server_settings) as (_, client):
        response = await client.post(
            "/sessions",
            headers={
                "Authorization": "Bearer test-token",
                "Idempotency-Key": "start-key-1",
                "Content-Type": "application/json",
            },
            content=b"x" * 65537,
        )

    assert response.status_code == 413
    body = response.json()
    assert body["code"] == "payload_too_large"
    assert body["request_id"]


async def test_chunked_request_body_over_64_kib_is_413(
    app_client: Callable[[Settings], Any], auth_server_settings: Settings
) -> None:
    async def chunks() -> AsyncIterator[bytes]:
        yield b"x" * 40000
        yield b"x" * 30000

    async with app_client(auth_server_settings) as (_, client):
        response = await client.post(
            "/sessions",
            headers={
                "Authorization": "Bearer test-token",
                "Idempotency-Key": "start-key-1",
                "Content-Type": "application/json",
            },
            content=chunks(),
        )

    assert response.status_code == 413
    assert response.json()["code"] == "payload_too_large"
