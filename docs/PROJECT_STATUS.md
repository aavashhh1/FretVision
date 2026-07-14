# FretVision Project Status

This file is the durable cross-agent handoff for Claude Code, Codex,
and human developers.

Update it only after implementation has been independently verified.
A task is not COMPLETE merely because code was generated.

## Last verified state

Last updated: 2026-07-14

### Completed

- Phase 1 — Canonical database artifacts and Batch D
  - Status: COMPLETE
  - Verification: 165/165 pgTAP assertions

- Phase 2 Step 1 — FastAPI foundation
  - Status: COMPLETE AND MERGED
  - Includes:
    - typed settings
    - asyncpg pool
    - JWT verification
    - health/readiness
    - request IDs
    - structured logging
    - Docker foundation

- Phase 2 Step 2 — JWT-backed ownership
  - Status: COMPLETE AND MERGED
  - Ownership source:
    - verified JWT sub
    - `AuthenticatedActor.user_id`
  - Request-body identity fields are never authoritative

- U11 / Phase 2 Step 2.5 — Profile provisioning
  - Status: COMPLETE AND MERGED
  - Decision: FastAPI lazy idempotent provisioning
  - ADR: `docs/architecture/06-adr-profile-provisioning.md`

## Current task

Phase 2 Step 3 — Transactional start-session command

Status:

`IMPLEMENTED AND VERIFIED ON FEATURE BRANCH — AWAITING USER REVIEW`

Branch:

`codex/feature/start-session-command`

Implementation contract approved 2026-07-14:

- `POST /sessions`
- authenticated ownership only from `AuthenticatedActor.user_id`
- `Idempotency-Key` header, 8–200 characters
- canonical operation-scoped SHA-256 request hash
- 64 KiB request-body limit, including chunked requests
- `201` response stored and replayed exactly
- `IDEMPOTENCY_TTL_SECONDS=86400` controls expiry metadata only;
  cleanup and expired-key reuse remain U12
- no migration, grant, RLS, trigger, seed, or database-test changes

## Required transaction behavior

The start-session command must:

1. Derive ownership from `AuthenticatedActor.user_id`.
2. Reserve the idempotency key.
3. Resolve replay or conflict.
4. Call `ensure_profile()` in the same transaction.
5. Read profile and revision snapshots.
6. Copy `fretting_hand_snapshot` from the profile.
7. Insert the session in `created` state.
8. Activate it using a server-generated timestamp.
9. Mark the idempotency record completed.
10. Commit.

## Open decisions and blockers

Record only decisions that are genuinely unresolved.

- U5 — Hosted JWT issuer/audience verification
- U6 — Hosted database connection mode
- U10 — CV latency budget
- U12 — Idempotency reaper policy
- U13 — Metric-version upgrade policy

U11 is resolved and must not be reopened.

## Latest verification baseline

Backend:

- Ruff lint: passed
- Ruff format: all 14 newly added files pass; the repository-wide
  `ruff format --check .` baseline remains non-green on pre-existing files
- Mypy: passed, 35 source files
- Unit tests: 72 passed, 8 integration tests deselected
- Integration tests: 8 passed, including 3 start-session transaction tests
- Scope check: `git diff --check` passed

Database:

- pgTAP: 165/165 baseline carried forward; not rerun because database
  artifacts were unchanged
- Existing migrations, grants, RLS, triggers, and seeds unchanged

Start-session integration verification covers:

- atomic profile provisioning, revision snapshot, session activation, and
  idempotency completion
- same-key/same-hash stored response replay
- same-key/different-hash `409`
- concurrent duplicate serialization to one session
- rollback of profile, reservation, and session side effects on failure

## Review gate and following task

Do not move Step 3 into Completed until user review is recorded.

After Step 3 approval, the exact next implementation task is:

Phase 2 Step 4 — Transactional ingest-batch command

Recommended branch:

`codex/feature/ingest-batch-command`

## Next-agent instructions

Before working:

1. Read `AGENTS.md` or `CLAUDE.md`.
2. Read this file.
3. Read the canonical architecture documents and accepted ADRs.
4. Check Git branch, status, log, and current tests.
5. Confirm that this file matches the committed repository.

After working:

1. Run all required verification.
2. Report results to the user.
3. Do not mark a task complete until the user has reviewed it.
4. Update this file in the same pull request as the completed task.
5. Record:
   - completed milestone
   - verification results
   - merged architectural decisions
   - unresolved blockers
   - exact next task
6. Never delete historical completed milestones.
7. Never record secrets, local passwords, tokens, or DSNs.
