# FretVision Backend

FastAPI service (Phase 2, Step 1 foundation): typed settings, an async asyncpg
database layer, pluggable JWT verification, health/readiness endpoints, structured
JSON logging, and request IDs. It is the sole writer to Postgres and connects as the
least-privilege role `fretvision_app`. This step contains **no** write routes,
aggregation, idempotency commands, or CORS — those arrive in later Phase 2 steps.

## Requirements

- Python 3.12
- [uv](https://docs.astral.sh/uv/) (pinned interpreter via `.python-version`)
- A running local Supabase stack with `fretvision_app` provisioned
  (see repo-root `README.md` and `scripts/`).

## Setup

```bash
cd backend
uv sync                 # creates backend/.venv from uv.lock
cp .env.example .env     # then fill in local values
```

`backend/.venv` is owned by this project and git-ignored. Do not reuse the
repository-root virtualenv.

## Run

```bash
uv run uvicorn app.main:app --reload
```

- `GET /healthz` — liveness. Returns 200 even when the database is down.
- `GET /readyz`  — readiness. Acquires a connection and runs `SELECT 1`; 503 on failure.
- `GET /me`      — protected; requires a bearer token. Returns only `{sub, role}`.

## JWT verification modes

`JWT_VERIFICATION_MODE` selects exactly one verifier — there is **no** automatic
fallback between them:

- `jwks` — **required hosted/production mode.** Verifies against `SUPABASE_JWKS_URL`
  using only the configured asymmetric algorithms (e.g. `ES256`), and validates
  signature, `kid`, `exp`, `nbf`, issuer, audience, role, and a non-empty UUID `sub`.
- `auth_server` — **local-development compatibility only.** Validates the bearer via
  the local Supabase Auth `/auth/v1/user` endpoint using `SUPABASE_URL` and the
  publishable key. FastAPI never holds the legacy HS256 secret. Production rejects this
  mode unless `ALLOW_AUTH_SERVER_IN_PROD=true`.

## Ownership convention

The backend connects as `fretvision_app`, which holds `BYPASSRLS`. RLS therefore
provides **no** protection on the write path — ownership is an application-layer
obligation.

Invariant: **body identity fields are never authoritative.** A request-body `user_id`,
`owner_id`, `profile_id`, or similar must never determine ownership. The only
authoritative user identifier is the verified JWT `sub`, exposed as
`AuthenticatedActor.user_id` (`app/auth/ownership.py`). `AuthenticatedActor` is
immutable and carries only `user_id` — no role, no raw claims. Role is authentication
metadata, not an ownership input.

Routes obtain the actor via the `ActorDep` dependency and pass the authoritative owner
to services **separately** from the request payload:

```python
await service.execute(owner_id=actor.user_id, command=command)
```

Never merge identity into the payload (no `body.model_dump()` plus `user_id`, no letting
a body field overwrite the subject). Future command DTOs may either reject unknown
fields or ignore them — that choice is per-DTO — but ownership must always come from
`actor.user_id`, never from the body.

## Database connection mode

`DB_CONNECTION_MODE` must be `direct` or `session`. Transaction-pooler mode is
forbidden (asyncpg uses prepared statements); startup also defensively rejects a DSN
on the Supabase transaction-pooler port `6543`.

## Tests

```bash
uv run pytest                 # deterministic unit tests only (no live DB)
uv run pytest -m integration  # requires TEST_DATABASE_URL (never DATABASE_URL)
uv run ruff check .
uv run mypy app
```

Integration tests use isolated, temporary data and never mutate seed/catalog rows,
truncate tables, or leave rows behind.
