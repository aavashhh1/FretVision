# ADR 06 — Profile Provisioning (U11)

**Status:** Accepted
**Date:** 2026-07-13
**Resolves:** U11 — "Profile provisioning strategy: auth trigger, FastAPI upsert, or first-login flow" (`05-claude-project-handoff.md` §8.3)

## Standing of this document

**An ADR cannot override canonical documents 01–04.** Precedence is unchanged:

```text
03-final-errata-patch.md                    ← highest
04-architecture-handoff-manifest.md
02-pass-2-baseline-consolidated-final.md
01-approved-pass-1-baseline.md + amendments
original brief
─────────────────────────────────────────
ADRs (this document) and 05-claude-project-handoff.md — decide/record within the
canonical envelope; never above it.
```

This ADR decides a question that documents 01–04 deliberately left open. It changes no ratified
decision, no schema, and no grant. If it is ever found to conflict with 01–04, the canonical
document wins and this ADR must be amended or withdrawn rather than reinterpreted.

## Context

`public.profiles` is 1:1 with `auth.users` (`user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE`), with `display_name text NULL` and `fretting_hand fretting_hand NOT NULL DEFAULT 'left'`. Nothing creates that row today.

Start-session copies `fretting_hand` from `profiles` into `sessions.fretting_hand_snapshot`
server-side (02 §4). A user who has never had a profile created would therefore break
start-session. Some component must guarantee the row exists before the first session starts,
without violating the ratified trust boundary: FastAPI is the sole writer, and ownership derives
solely from the JWT `sub`.

## Decision

**FastAPI performs lazy, idempotent profile provisioning.**

A repository function joins the caller's existing transaction on the caller's connection:

```python
async def ensure_profile(connection: asyncpg.Connection, *, user_id: UUID) -> ProfileSnapshot
```

It executes exactly two statements:

```sql
INSERT INTO public.profiles (user_id)
VALUES ($1)
ON CONFLICT (user_id) DO NOTHING;

SELECT user_id, display_name, fretting_hand
FROM public.profiles
WHERE user_id = $1;
```

and returns an immutable `ProfileSnapshot(user_id, display_name, fretting_hand)`.

`user_id` is always the caller's `AuthenticatedActor.user_id`, derived solely from the verified
JWT `sub`. The provisioning surface accepts no request DTO; no command DTO may declare `user_id`,
`owner_id`, `profile_id`, or `fretting_hand_snapshot`.

### Defaults are created, never overwritten

The insert is `ON CONFLICT ... DO NOTHING`. **`ON CONFLICT ... DO UPDATE` is forbidden here.** The
insert names only `user_id`, so `display_name` and `fretting_hand` are supplied exclusively by the
database defaults on first creation and are structurally unreachable from the provisioning path
afterwards. Re-provisioning an existing profile is a no-op that reads the row and returns it.
Provisioning is therefore safe to call on every start-session, forever.

### Start-session defensively ensures the profile

Start-session (Phase 2 Step 3 — **not implemented in this branch**) calls `ensure_profile` inside
the single explicit transaction it already opens:

```text
BEGIN
  reserve idempotency record (INSERT ... ON CONFLICT DO NOTHING; SELECT ... FOR UPDATE on duplicate)
  ensure_profile(connection, user_id=actor.user_id)
  read profile + revision snapshots
  INSERT session (lifecycle = 'created')
  UPDATE session -> 'active' (server-generated activated_at)
  complete idempotency record (state='completed', response_status, response_body)
COMMIT
```

Because provisioning shares that transaction, it commits with the session or rolls back with it;
a failed start can never leave an orphaned profile row, and start-session tolerates a missing
profile by construction rather than by luck.

### Errors are domain errors

`ensure_profile` raises `ProfileIdentityNotFoundError` (the `user_id` has no `auth.users` row — the
foreign key is violated, e.g. a still-valid JWT for a deleted subject) or
`ProfileSnapshotUnavailableError` (the row could not be read back, or failed the snapshot contract).
Raw asyncpg exceptions never escape the repository. These are **domain** errors, not HTTP errors:
no production route invokes provisioning yet, so the status-code mapping is deferred to the
command/API layer in Step 3.

## Options rejected

| Option | Why rejected |
|---|---|
| **`auth.users` database trigger** | Database triggers are reserved for **hard invariants** (04 §1, 05 §4). Profile provisioning is application orchestration, and FastAPI is the ratified write and transaction owner. A trigger would move a write outside FastAPI's transaction boundary and put orchestration back in Postgres — the same class of decision as the withdrawn command RPCs. |
| **Supabase Auth hook** | Same objection, plus an out-of-band write path that FastAPI neither owns nor can roll back with the command that depends on it. |
| **Browser-direct profile `INSERT`** | Violates the hard constraint that **all writes are FastAPI-only**. `authenticated` holds `SELECT` on `profiles` and nothing more; granting `INSERT` would widen the ratified client privilege surface, which pgTAP test 005 verifies. |
| **Client-only first-login flow** | Insufficient. The client can fail, be offline, be a non-browser caller, or simply never run the flow; a user whose first-login write was lost would then be unable to start a session. The server cannot depend on a client-side guarantee. |
| **Service-role HTTP call from FastAPI** | Introduces a privileged credential (`SUPABASE_SECRET_KEY`) for a write FastAPI can already perform directly as `fretvision_app`, and it cannot participate in the start-session transaction. |
| **Request-body `user_id`** | An authorization vulnerability, not a validation slip (05 §6). Ownership derives only from the JWT `sub`. |

## Consequences

- No migration, trigger, grant, or schema change is required. `fretvision_app` already holds
  `INSERT`/`SELECT` on `public.profiles` (`scripts/grant_fretvision_app.sql`). The verified 165/165
  database contract is untouched.
- Every command that needs a profile must call `ensure_profile` inside its own transaction. It is
  cheap (one conflict no-op insert) and safe to repeat.
- A profile therefore exists from a user's first *session start*, not from signup. A user who signs
  up and never practices has no profile row. This is intended: the row's only purpose is to carry
  practice preferences into a session snapshot.
- The HTTP mapping of `ProfileIdentityNotFoundError` and `ProfileSnapshotUnavailableError` is an
  open Step 3 item. Until a route invokes provisioning, no mapping is decided.
