"""HTTP contract tests for authenticated sample-batch ingestion."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any
from uuid import UUID

from app.auth.dependencies import require_identity
from app.auth.models import VerifiedIdentity
from app.domain.batches import (
    IngestBatchCommand,
    IngestBatchExecutionResult,
    IngestBatchResponse,
)
from app.settings import Settings

USER_A = UUID("aaaaaaaa-0000-4000-8000-000000000001")
USER_B = UUID("bbbbbbbb-0000-4000-8000-000000000002")
SESSION_A = UUID("cccccccc-0000-4000-8000-000000000003")
SESSION_B = UUID("dddddddd-0000-4000-8000-000000000004")
SAMPLE_ID = UUID("eeeeeeee-0000-4000-8000-000000000005")


class SpyIngestBatchHandler:
    def __init__(self) -> None:
        self.calls: list[tuple[UUID, UUID, str, IngestBatchCommand]] = []

    async def execute(
        self,
        *,
        owner_id: UUID,
        session_id: UUID,
        idempotency_key: str,
        command: IngestBatchCommand,
    ) -> IngestBatchExecutionResult:
        self.calls.append((owner_id, session_id, idempotency_key, command))
        return IngestBatchExecutionResult(
            response_status=200,
            response=IngestBatchResponse(
                session_id=session_id,
                accepted_count=len(command.samples),
                first_seq=command.samples[0].seq,
                last_seq=command.samples[-1].seq,
            ),
        )


async def test_route_uses_actor_and_path_session_not_body_identity(
    app_client: Callable[[Settings], Any], auth_server_settings: Settings
) -> None:
    spy = SpyIngestBatchHandler()
    async with app_client(auth_server_settings) as (app, client):
        app.state.services.ingest_batch = spy
        app.dependency_overrides[require_identity] = lambda: VerifiedIdentity(
            sub=USER_A,
            role="authenticated",
        )
        response = await client.post(
            f"/sessions/{SESSION_A}/samples/batches",
            headers={
                "Authorization": "Bearer token",
                "Idempotency-Key": "batch-key-1",
            },
            json={
                "user_id": str(USER_B),
                "session_id": str(SESSION_B),
                "samples": [
                    {
                        "id": str(SAMPLE_ID),
                        "seq": 0,
                        "is_valid": True,
                        "placement_accuracy": 0.8,
                        "confidence": 0.9,
                        "interval_end_offset_ms": 2500,
                    }
                ],
            },
        )

    assert response.status_code == 200
    assert response.json() == {
        "session_id": str(SESSION_A),
        "accepted_count": 1,
        "first_seq": 0,
        "last_seq": 0,
    }
    assert len(spy.calls) == 1
    owner_id, session_id, key, command = spy.calls[0]
    assert owner_id == USER_A
    assert session_id == SESSION_A
    assert key == "batch-key-1"
    assert set(command.model_fields_set) == {"samples"}


async def test_route_rejects_invalid_sample_shape_before_handler(
    app_client: Callable[[Settings], Any], auth_server_settings: Settings
) -> None:
    spy = SpyIngestBatchHandler()
    async with app_client(auth_server_settings) as (app, client):
        app.state.services.ingest_batch = spy
        app.dependency_overrides[require_identity] = lambda: VerifiedIdentity(
            sub=USER_A,
            role="authenticated",
        )
        response = await client.post(
            f"/sessions/{SESSION_A}/samples/batches",
            headers={
                "Authorization": "Bearer token",
                "Idempotency-Key": "batch-key-1",
            },
            json={
                "samples": [
                    {
                        "id": str(SAMPLE_ID),
                        "seq": 0,
                        "is_valid": True,
                        "interval_end_offset_ms": 2500,
                    }
                ]
            },
        )

    assert response.status_code == 422
    assert response.json()["code"] == "validation_error"
    assert spy.calls == []
