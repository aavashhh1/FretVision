"""Request-scoped context shared between middleware and logging."""

from __future__ import annotations

from contextvars import ContextVar

# The current request id, set by the request-id ASGI middleware and read by the
# JSON log formatter. ``None`` outside of a request scope.
request_id_var: ContextVar[str | None] = ContextVar("request_id", default=None)
