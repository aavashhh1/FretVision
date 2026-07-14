"""Pure-ASGI enforcement of the ratified 64 KiB request-body limit."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any

from fastapi.responses import JSONResponse

from app.context import request_id_var

MAX_REQUEST_BODY_BYTES = 64 * 1024

ASGIApp = Callable[
    [dict[str, Any], Callable[[], Awaitable[dict[str, Any]]], Callable[..., Any]],
    Awaitable[None],
]


class _BodyTooLarge(Exception):
    pass


class RequestBodyLimitMiddleware:
    """Reject HTTP request bodies larger than ``max_body_bytes`` with 413."""

    def __init__(self, app: ASGIApp, *, max_body_bytes: int = MAX_REQUEST_BODY_BYTES) -> None:
        self._app = app
        self._max_body_bytes = max_body_bytes

    async def __call__(
        self,
        scope: dict[str, Any],
        receive: Callable[[], Awaitable[dict[str, Any]]],
        send: Callable[..., Any],
    ) -> None:
        if scope.get("type") != "http":
            await self._app(scope, receive, send)
            return

        content_length = self._content_length(scope)
        if content_length is not None and content_length > self._max_body_bytes:
            await self._reject(scope, receive, send)
            return

        try:
            messages = await self._read_body(receive)
        except _BodyTooLarge:
            await self._reject(scope, receive, send)
            return

        index = 0

        async def replay_receive() -> dict[str, Any]:
            nonlocal index
            if index < len(messages):
                message = messages[index]
                index += 1
                return message
            return await receive()

        await self._app(scope, replay_receive, send)

    async def _read_body(
        self,
        receive: Callable[[], Awaitable[dict[str, Any]]],
    ) -> list[dict[str, Any]]:
        messages: list[dict[str, Any]] = []
        received = 0
        while True:
            message = await receive()
            messages.append(message)
            if message.get("type") != "http.request":
                return messages
            body = message.get("body", b"")
            if isinstance(body, bytes):
                received += len(body)
            if received > self._max_body_bytes:
                raise _BodyTooLarge
            if not message.get("more_body", False):
                return messages

    @staticmethod
    def _content_length(scope: dict[str, Any]) -> int | None:
        for name, value in scope.get("headers", []):
            if name.lower() == b"content-length":
                try:
                    return int(value)
                except (TypeError, ValueError):
                    return None
        return None

    @staticmethod
    async def _reject(
        scope: dict[str, Any],
        receive: Callable[[], Awaitable[dict[str, Any]]],
        send: Callable[..., Any],
    ) -> None:
        response = JSONResponse(
            status_code=413,
            content={
                "code": "payload_too_large",
                "message": "Request body exceeds 64 KiB",
                "request_id": request_id_var.get(),
            },
        )
        await response(scope, receive, send)
