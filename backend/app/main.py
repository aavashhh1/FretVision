"""Application factory, lifespan, and ASGI entrypoint.

The request-id middleware is applied as the outermost pure-ASGI layer so every
response — including generic 500s produced above the router — carries an
``x-request-id`` header and a request-scoped log context. Settings are constructed
lazily in lifespan so importing this module never requires a configured environment.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI

from app.api import health, protected, sessions
from app.asgi_body_limit import RequestBodyLimitMiddleware
from app.asgi_request_id import RequestIdMiddleware
from app.errors import register_error_handlers
from app.logging import configure_logging
from app.services import AppServices
from app.settings import Settings


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings: Settings = getattr(app.state, "settings", None) or Settings()
    configure_logging(settings.log_level)
    app.state.settings = settings

    services = await AppServices.create(settings)
    app.state.services = services
    try:
        yield
    finally:
        await services.aclose()


def create_app(settings: Settings | None = None) -> FastAPI:
    """Create the FastAPI application (without the outer request-id ASGI wrapper)."""
    configure_logging(settings.log_level if settings is not None else "INFO")
    app = FastAPI(title="FretVision Backend", version="0.1.0", lifespan=lifespan)
    app.state.settings = settings
    register_error_handlers(app)
    app.include_router(health.router)
    app.include_router(protected.router)
    app.include_router(sessions.router)
    return app


def build_asgi_app(settings: Settings | None = None) -> Any:
    """Wrap the FastAPI app in the outermost request-id middleware."""
    return RequestIdMiddleware(RequestBodyLimitMiddleware(create_app(settings)))


# Uvicorn entrypoint: `uvicorn app.main:app`.
app = build_asgi_app()
