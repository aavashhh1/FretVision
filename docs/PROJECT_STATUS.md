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

Suggested branch:

`feature/start-session-command`

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

- Ruff: passed
- Mypy: passed
- Unit tests: update after each merged task
- Integration tests: update after each merged task

Database:

- pgTAP: 165/165
- Existing migrations, grants, RLS, triggers, and seeds unchanged

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