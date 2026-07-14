# FretVision — Claude Code Instructions

## Project purpose

FretVision is a browser-first guitar-practice application. Browser-side computer vision evaluates fretting-hand placement while raw webcam frames remain on the user's device.

Planned stack:

- Frontend: Next.js with TypeScript
- Backend: FastAPI
- Database and authentication: Supabase PostgreSQL and Supabase Auth
- Browser CV: MediaPipe Hands and OpenCV.js
- Database verification: pgTAP through the Supabase CLI

## Current milestone

**Phase 1 — Canonical Artifacts and Batch D — is complete and verified.**

Verified state:

- Migrations `20260710000001` through `20260710000007` apply cleanly.
- `fretvision_app` is provisioned outside migrations.
- Least-privilege grants and RLS boundaries are verified.
- Database preflight checks pass.
- Phase 1 tests: 138 assertions passing.
- Phase 2 tests: 27 assertions passing.
- Total: **165/165 assertions passing**.
- Final result: `ALL BATCH D TESTS PASSED`.

Do not redesign the approved database model without an explicit architecture decision.

## Source of truth

Read these before planning or changing architecture:

1. `docs/architecture/03-final-errata-patch.md`
2. `docs/architecture/04-architecture-handoff-manifest.md`
3. `docs/architecture/02-pass-2-baseline-consolidated-final.md`
4. `docs/architecture/01-approved-pass-1-baseline.md`
5. `docs/architecture/05-claude-project-handoff.md`
6. `README.md`
7. `supabase/migrations/`
8. `supabase/tests/database/`
9. `scripts/README.md`
10. `scripts/bootstrap_role.sql`
11. `scripts/grant_fretvision_app.sql`

`05-claude-project-handoff.md` records and summarizes; it never overrides documents 01–04.

The migrations, scripts, and 165 passing tests are the verified executable contract. If a canonical document conflicts with a verified artifact, report the contradiction rather than silently changing either side.

## Durable project status and handoff

The changing project status is maintained in:

`docs/PROJECT_STATUS.md`

At the beginning of every task:

1. Read `docs/PROJECT_STATUS.md`.
2. Compare it with the current Git branch, Git log, implementation, and tests.
3. Report any inconsistency before editing.
4. Treat committed code and tests as stronger evidence than a status claim.

At the end of every verified task:

1. Do not mark the task complete based only on generated code.
2. Run the required linting, type checking, unit tests, integration tests,
   and scope checks.
3. Wait for user review when requested.
4. Update `docs/PROJECT_STATUS.md` in the same branch and pull request.
5. Record:
   - what was completed;
   - verification evidence;
   - relevant commits or ADRs;
   - remaining unresolved decisions;
   - the exact recommended next task and branch name.
6. Keep this `CLAUDE.md` focused on stable instructions.
7. Do not duplicate detailed changing status here.

Before finishing, explicitly report whether
`docs/PROJECT_STATUS.md` was updated.
Do not commit or push unless the user explicitly requests it.

## Accepted ADRs

ADRs decide questions the canonical documents left open. **An ADR can never override canonical documents 01–04.** If an ADR conflicts with 01–04, the canonical document wins and the ADR must be amended or withdrawn.

| ADR | Decides |
|---|---|
| `docs/architecture/06-adr-profile-provisioning.md` | **U11 — RESOLVED.** Profile provisioning is FastAPI lazy, idempotent `INSERT ... ON CONFLICT (user_id) DO NOTHING` plus a separate `SELECT`, run inside the caller's transaction. No `auth.users` trigger, no Auth hook, no browser-direct insert, no client-only first-login flow, no service-role call, no request-body `user_id`. Existing `display_name` and `fretting_hand` are never overwritten. |

## Required local commands

Run the complete database verification from the repository root:

```powershell
$env:SUPABASE_DB_CONTAINER = 'supabase_db_FretVision'
$env:FRETVISION_APP_PASSWORD = '<local password with at least 24 characters>'
.\scripts\run_db_tests.ps1
```

Run a reset without the complete test suite:

```powershell
$env:SUPABASE_DB_CONTAINER = 'supabase_db_FretVision'
$env:FRETVISION_APP_PASSWORD = '<local password with at least 24 characters>'
.\scripts\reset_local.ps1
```

Use the repository-local Supabase CLI:

```powershell
npx supabase status
npx supabase db reset
```

Do not assume a global `supabase` or host `psql` installation exists. The validated Windows workflow can execute `psql` inside the local Supabase database container.

## Architecture constraints

- Keep raw webcam frames and full per-frame landmarks on the client.
- FastAPI owns all multi-step business transactions and all writes.
- The browser uses the Supabase publishable key and user JWT for approved reads.
- The backend connects with `fretvision_app`.
- Ownership derives only from JWT `sub`, never from a request-body `user_id`.
- Never place the `fretvision_app` password in migrations.
- Preserve published catalog immutability.
- Preserve session lifecycle and deferred integrity constraints.
- Preserve RLS isolation and the verified privilege surfaces.
- Do not add an attempts table unless architecture is explicitly revised.
- One session is one continuous practice period against one immutable revision pair.
- Do not reintroduce Postgres command RPC functions.
- Do not use transaction-pooler mode with prepared statements.
- Do not push migrations to hosted Supabase without explicit approval and a green local suite.

## Security rules

- Never commit `.env`, `.env.local`, passwords, secret keys, access tokens, or generated credentials.
- Do not display secrets in logs or command arguments.
- Treat destructive database and Git operations as approval-required.
- Keep application roles least-privileged.
- `fretvision_app` has `BYPASSRLS`; backend ownership checks are therefore security-critical.

## Development workflow

Before editing:

1. Read the relevant architecture documents, implementation, and tests.
2. State the proposed change and affected files.
3. Preserve current contracts unless the task explicitly changes them.
4. Ask before destructive, hosted, or architecture-changing actions.

After editing:

1. Run the narrowest relevant checks.
2. Run the complete database suite for schema, trigger, grant, RLS, view, seed, bootstrap, or database-test changes.
3. Run `git diff --check`.
4. Summarize changed files and test evidence.
5. Do not claim success without command output.

Prefer focused changes over broad refactors.

## Phase 2 sequence

Phase 1 is closed. Start Phase 2 with a written plan.

1. Scaffold FastAPI.
2. Add typed settings, `DATABASE_URL`, and async PostgreSQL connectivity using `fretvision_app`.
3. Add JWKS JWT verification, ownership-from-`sub`, health/readiness, structured JSON logs, and request IDs.
4. Implement transactional start, batch, complete, and abandon commands with idempotency.
5. Implement deterministic aggregation and scoring.
6. Verify direct-read analytics with real JWT-backed RLS.
7. Resolve the latency budget and profile-provisioning decisions.
8. Scaffold the Next.js TypeScript frontend and Supabase Auth.
9. Add MediaPipe/OpenCV.js incrementally.
10. Add CI for migrations, database tests, backend tests, and Docker builds.

Do not start CV implementation before the backend trust boundary and latency budget are defined.