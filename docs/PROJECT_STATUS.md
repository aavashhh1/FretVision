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

- Phase 2 Step 3 — Transactional start-session command
  - Status: COMPLETE AND MERGED
  - Merge commit: `622ae4d`
  - Includes:
    - authenticated `POST /sessions`
    - user-scoped start-session idempotency
    - lazy profile provisioning in the command transaction
    - server-copied profile and revision snapshots
    - atomic `created` to `active` transition
    - 64 KiB request-body enforcement

## Current task

Phase 2 Step 4 — Transactional ingest-batch command

Status:

`IMPLEMENTED AND VERIFIED ON FEATURE BRANCH — AWAITING USER REVIEW`

Branch:

`feature/ingest-batch-command`

Implementation contract approved 2026-07-14:

- `POST /sessions/{session_id}/samples/batches`
- authenticated ownership only from `AuthenticatedActor.user_id`
- `Idempotency-Key` header, 8–200 characters
- canonical SHA-256 request hash includes the authoritative path session
- non-empty, internally contiguous batches with unique sample UUIDs
- strictly increasing interval offsets within and across persisted chunks
- owned session row locked and required to be `active`
- first batch starts at `seq=0`; later batches continue persisted `max(seq)+1`
- synchronous `200` response stored and replayed exactly
- `IDEMPOTENCY_TTL_SECONDS=86400` controls expiry metadata only;
  cleanup and expired-key reuse remain U12
- no migration, grant, RLS, trigger, seed, or database-test changes

## Required transaction behavior

The ingest-batch command must:

1. Derive ownership from `AuthenticatedActor.user_id`.
2. Reserve the user-scoped `ingest_batch` idempotency key.
3. Resolve replay or hash conflict.
4. Lock the owned session and require `active` lifecycle.
5. Read the persisted sample sequence and interval-offset tail.
6. Require the batch to continue both ordered sequences.
7. Insert every structurally validated sample.
8. Mark the idempotency record completed with the session and exact response.
9. Commit.

Any error rolls back both the sample rows and idempotency reservation.

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
- Ruff format: all 9 newly added Step 4 files pass; the repository-wide
  `ruff format --check .` baseline remains non-green on pre-existing files
- Mypy: passed, 38 source files
- Unit tests: 93 passed, 12 integration tests deselected
- Integration tests: 12 passed, including 4 ingest-batch transaction tests
- Scope check: `git diff --check` passed

Database:

- pgTAP: 165/165 baseline carried forward; not rerun because database
  artifacts were unchanged
- Existing migrations, grants, RLS, triggers, and seeds unchanged

Ingest-batch integration verification covers:

- atomic sample insertion and idempotency completion
- same-key/same-hash stored response replay
- same-key/different-hash `409`
- concurrent duplicate serialization to one batch
- cross-user session denial and terminal-session rejection
- persisted sequence continuation enforcement
- rollback of all new rows and the reservation on sample-identity conflict

## Review gate and following task

Do not move Step 4 into Completed until user review is recorded.

After Step 4 approval, the exact next implementation task is:

Phase 2 Step 5 — Transactional complete-session command

Recommended branch:

`feature/complete-session-command`

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
