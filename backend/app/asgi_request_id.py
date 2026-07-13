"""Pure ASGI middleware for request-id propagation and access logging.

Implemented at the ASGI layer (not ``BaseHTTPMiddleware`` / ``@app.middleware``) so it
composes cleanly with the lifespan protocol and streaming responses. It validates an
incoming ``X-Request-ID``, generating a fresh UUID when it is missing or unsafe, binds
it to a ``ContextVar`` (reset in ``finally``), echoes it on the response, and emits one
structured access log line per request. It never logs headers, tokens, or bodies.
"""

from __future__ import annotations

import logging
import re
import time
import uuid
from typing import Any

from app.context import request_id_var

_ASGISend = Any
_ASGIReceive = Any
_Scope = dict[str, Any]
_Message = dict[str, Any]

# A bounded, injection-safe request id: printable token, no control characters.
_SAFE_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

_REQUEST_ID_HEADER = b"x-request-id"

logger = logging.getLogger("fretvision.access")


def _normalize_request_id(raw: bytes | None) -> str:
    if raw is not None:
        try:
            candidate = raw.decode("latin-1").strip()
        except UnicodeDecodeError:
            candidate = ""
        if _SAFE_REQUEST_ID.match(candidate):
            return candidate
    return str(uuid.uuid4())


class RequestIdMiddleware:
    """ASGI middleware wrapping the application with request-id + access logging."""

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(
        self, scope: _Scope, receive: _ASGIReceive, send: _ASGISend
    ) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers") or [])
        request_id = _normalize_request_id(headers.get(_REQUEST_ID_HEADER))
        token = request_id_var.set(request_id)

        start = time.perf_counter()
        status_code = 500

        async def send_wrapper(message: _Message) -> None:
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = message["status"]
                raw_headers = list(message.get("headers") or [])
                raw_headers = [
                    (name, value)
                    for name, value in raw_headers
                    if name.lower() != _REQUEST_ID_HEADER
                ]
                raw_headers.append((_REQUEST_ID_HEADER, request_id.encode("latin-1")))
                message["headers"] = raw_headers
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            duration_ms = round((time.perf_counter() - start) * 1000, 3)
            logger.info(
                "request",
                extra={
                    "http_method": scope.get("method"),
                    "http_path": scope.get("path"),
                    "http_status": status_code,
                    "duration_ms": duration_ms,
                },
            )
            request_id_var.reset(token)
