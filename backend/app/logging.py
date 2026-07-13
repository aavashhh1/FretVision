"""Structured JSON logging.

The formatter emits a curated, safe set of fields plus the current request id. It
never serializes arbitrary record state, and it scrubs any field whose name matches a
sensitive-key denylist as defense in depth — secrets, JWTs, and DSNs must never reach
the logs.
"""

from __future__ import annotations

import json
import logging
from datetime import UTC, datetime
from typing import Any

from app.context import request_id_var

# Standard LogRecord attributes we do not want to duplicate as "extra" fields.
_STANDARD_RECORD_ATTRS = frozenset(vars(logging.makeLogRecord({})).keys()) | {
    "message",
    "asctime",
    "taskName",
}

# Field names that must never be logged, even if passed via ``extra``.
_SENSITIVE_KEYS = (
    "authorization",
    "token",
    "jwt",
    "password",
    "secret",
    "api_key",
    "apikey",
    "database_url",
    "dsn",
    "cookie",
)


def _is_sensitive(key: str) -> bool:
    lowered = key.lower()
    return any(marker in lowered for marker in _SENSITIVE_KEYS)


class JsonFormatter(logging.Formatter):
    """Render log records as single-line JSON objects."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }

        request_id = request_id_var.get()
        if request_id is not None:
            payload["request_id"] = request_id

        # Include curated extra fields, skipping standard attributes and any
        # sensitive key names.
        for key, value in record.__dict__.items():
            if key in _STANDARD_RECORD_ATTRS or key.startswith("_"):
                continue
            if _is_sensitive(key):
                payload[key] = "[redacted]"
            else:
                payload[key] = value

        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)

        return json.dumps(payload, default=str, separators=(",", ":"))


def configure_logging(level: str = "INFO") -> None:
    """Install the JSON formatter on the root and uvicorn loggers."""
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level.upper())

    # Route uvicorn's own loggers through the same JSON handler. Disable the
    # default access logger; our request-id middleware emits access lines.
    for name in ("uvicorn", "uvicorn.error"):
        logger = logging.getLogger(name)
        logger.handlers = [handler]
        logger.propagate = False
    access_logger = logging.getLogger("uvicorn.access")
    access_logger.handlers = []
    access_logger.propagate = False
    access_logger.disabled = True
