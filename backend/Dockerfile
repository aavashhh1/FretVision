# syntax=docker/dockerfile:1

# ---- builder ---------------------------------------------------------------
# Base on python:3.12-slim so the virtualenv is built against the exact
# interpreter the runtime stage uses (avoids a copied-venv interpreter
# mismatch). uv is pinned by exact version and copied in from its published
# image; replace the tag with a @sha256 digest for fully reproducible builds.
FROM python:3.12-slim-bookworm AS builder
COPY --from=ghcr.io/astral-sh/uv:0.11.3 /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0
WORKDIR /app

# Cache-friendly locked dependency layer: resolve/install deps only, without
# the application, so this layer is reused unless the lockfile changes.
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-install-project

# Then bring in the application and complete the locked sync (non-library
# layout: package=false, so this validates the environment against the lock).
COPY app ./app
RUN uv sync --locked --no-dev

# ---- runtime ---------------------------------------------------------------
FROM python:3.12-slim-bookworm AS runtime
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /app

# Non-root runtime user.
RUN groupadd --system app \
 && useradd --system --gid app --home-dir /app --shell /usr/sbin/nologin app

# Copy only the resolved virtualenv and the application source. No .env, no
# tests, no lockfiles are shipped in the runtime image (see .dockerignore).
COPY --from=builder --chown=app:app /app/.venv /app/.venv
COPY --chown=app:app app ./app

USER app
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
