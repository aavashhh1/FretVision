# FretVision Backend

FastAPI service with typed settings, an async asyncpg database layer, pluggable JWT
verification, health/readiness endpoints, structured JSON logging, request IDs, and the
transactional start-session command. It is the sole writer to Postgres and connects as
the least-privilege role `fretvision_app`. Batch ingestion, completion, abandonment,
aggregation, and CORS remain later Phase 2 work.

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
- `POST /sessions` — protected, idempotent start-session command. Requires an
  `Idempotency-Key` header (8–200 characters).

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

## Profile provisioning (U11 — `docs/architecture/06-adr-profile-provisioning.md`)

`public.profiles` rows are created **lazily and idempotently by FastAPI** — not by an
`auth.users` trigger, an Auth hook, a browser-direct insert, or a client first-login flow.
`app/repositories/profiles.py` exposes:

```python
async def ensure_profile(connection: asyncpg.Connection, *, user_id: UUID) -> ProfileSnapshot
```

It runs `INSERT INTO public.profiles (user_id) VALUES ($1) ON CONFLICT (user_id) DO NOTHING`
followed by a separate `SELECT`, and returns an immutable `ProfileSnapshot`. Because the
insert names only `user_id` and never uses `DO UPDATE`, provisioning creates database
defaults for a first-time user and **can never overwrite an existing `display_name` or
`fretting_hand`**. It is safe to call on every command, forever.

**Transaction rule:** `ensure_profile` never opens, commits, or rolls back a transaction. It
runs on a connection the caller already holds inside its own explicit transaction. Start-session
(Step 3) will call it in this order:

```text
BEGIN
  reserve idempotency record
  ensure_profile(connection, user_id=actor.user_id)
  read profile + revision snapshots
  INSERT session (created)  ->  UPDATE session (active)
  complete idempotency record
COMMIT
```

`user_id` is always `AuthenticatedActor.user_id`, from the verified JWT `sub`. The repository
accepts no request DTO. Failures raise the **domain** errors `ProfileIdentityNotFoundError` and
`ProfileSnapshotUnavailableError` (`app/domain/profiles.py`); raw asyncpg exceptions never escape
the repository, and the start-session command maps them without exposing database details.

## Start session

`POST /sessions` accepts only the validated command fields:

```json
{
  "exercise_revision_id": "00000000-0000-0000-0000-000000000000",
  "target_position_revision_id": "00000000-0000-0000-0000-000000000000",
  "declared_interval_ms": 2500
}
```

Ownership is passed separately from `AuthenticatedActor.user_id`. Body-supplied identity or
reproducibility fields are ignored and can never override the verified owner or server snapshots.
The command reserves the user-scoped key, provisions the profile, reads the published revision
pair, inserts the session as `created`, transitions it to `active` with database `now()`, and stores
the exact `201` response — all inside one explicit transaction. Same-key/same-body requests replay
the stored response; the same key with a different canonical request hash returns `409`.

`IDEMPOTENCY_TTL_SECONDS` defaults to 86400 and controls expiry metadata only. Cleanup and expired-
key reuse remain the unresolved U12 reaper policy. Request bodies are capped at 64 KiB.

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

The profile-provisioning integration test is **double-gated** and additionally needs
`TEST_ADMIN_DATABASE_URL`. `fretvision_app` has no privilege on the `auth` schema, so the
admin DSN is used **only** to create and delete the `auth.users` fixture row (a fresh UUID and
`@fretvision.invalid` e-mail per run, removed in `finally`, cascading the profile away). All
provisioning and profile reads/writes go through `fretvision_app`. Both DSNs must point at a
local host; a non-local host is skipped rather than mutated.
