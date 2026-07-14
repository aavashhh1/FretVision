"""Common error contract: typed errors, a JSON envelope, and explicit handlers.

Every error response is ``{"code", "message", "request_id"}``. Authentication failures
map to 401 with ``WWW-Authenticate: Bearer``; readiness failures to 503;
``HTTPException`` preserves its status and headers; request validation preserves 422;
and only genuinely unexpected exceptions become a generic 500. Internal exception
detail, claims, DSNs, and secrets are never placed in the response body.
"""

from __future__ import annotations

import logging
from collections.abc import Mapping
from typing import Any

from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.context import request_id_var

logger = logging.getLogger("fretvision.error")


class ErrorEnvelope(BaseModel):
    code: str
    message: str
    request_id: str | None = None


class AppError(Exception):
    """Base class for errors that map to a controlled HTTP response."""

    status_code: int = 500
    code: str = "internal_error"
    headers: dict[str, str] | None = None

    def __init__(self, message: str | None = None) -> None:
        self.message = message or self.default_message
        super().__init__(self.message)

    default_message: str = "Internal server error"


class AuthError(AppError):
    """Authentication/authorization failure. Mapped to 401 by the handler only."""

    status_code = 401
    code = "unauthorized"
    default_message = "Authentication required"
    headers = {"WWW-Authenticate": "Bearer"}


class ReadinessError(AppError):
    """The service is not ready to serve traffic (e.g. the database is unreachable)."""

    status_code = 503
    code = "not_ready"
    default_message = "Service not ready"


class IdempotencyConflictHttpError(AppError):
    """An idempotency key was reused for a different command payload."""

    status_code = 409
    code = "idempotency_key_conflict"
    default_message = "Idempotency key was already used for a different request"


class SessionTargetNotFoundHttpError(AppError):
    """The requested published exercise/target revision pair is unavailable."""

    status_code = 404
    code = "session_target_not_found"
    default_message = "Published exercise and target revision pair not found"


class SessionNotFoundHttpError(AppError):
    """A session is absent or not owned by the authenticated actor."""

    status_code = 404
    code = "session_not_found"
    default_message = "Session not found"


class SessionNotActiveHttpError(AppError):
    """A command requires an active session but found another lifecycle."""

    status_code = 409
    code = "session_not_active"
    default_message = "Session is not active"


class SampleBatchConflictHttpError(AppError):
    """A batch conflicts with already persisted session sample state."""

    status_code = 409
    code = "sample_batch_conflict"
    default_message = "Sample batch conflicts with persisted session state"


def _envelope_response(
    status_code: int, code: str, message: str, headers: Mapping[str, str] | None = None
) -> JSONResponse:
    body = ErrorEnvelope(
        code=code, message=message, request_id=request_id_var.get()
    )
    return JSONResponse(status_code=status_code, content=body.model_dump(), headers=headers)


async def _handle_app_error(_: Request, exc: AppError) -> JSONResponse:
    return _envelope_response(exc.status_code, exc.code, exc.message, exc.headers)


async def _handle_http_exception(_: Request, exc: StarletteHTTPException) -> JSONResponse:
    # Preserve the status and any headers (e.g. WWW-Authenticate) the caller set.
    detail = exc.detail if isinstance(exc.detail, str) else "HTTP error"
    return _envelope_response(exc.status_code, f"http_{exc.status_code}", detail, exc.headers)


async def _handle_validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
    # Preserve 422 but strip input values; expose only safe location/type info.
    safe_errors: list[dict[str, Any]] = [
        {"loc": err.get("loc"), "type": err.get("type"), "msg": err.get("msg")}
        for err in exc.errors()
    ]
    body = ErrorEnvelope(
        code="validation_error",
        message="Request validation failed",
        request_id=request_id_var.get(),
    ).model_dump()
    body["errors"] = safe_errors
    return JSONResponse(status_code=422, content=body)


async def _handle_unexpected(_: Request, exc: Exception) -> JSONResponse:
    logger.exception("unhandled_exception", extra={"error_type": type(exc).__name__})
    return _envelope_response(500, "internal_error", "Internal server error")


def register_error_handlers(app: Any) -> None:
    """Register all explicit exception handlers on the FastAPI app."""
    app.add_exception_handler(AuthError, _handle_app_error)
    app.add_exception_handler(ReadinessError, _handle_app_error)
    app.add_exception_handler(AppError, _handle_app_error)
    app.add_exception_handler(StarletteHTTPException, _handle_http_exception)
    app.add_exception_handler(RequestValidationError, _handle_validation_error)
    app.add_exception_handler(Exception, _handle_unexpected)
