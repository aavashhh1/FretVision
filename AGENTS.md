# FretVision Agent Instructions

This repository may be developed using Codex, Claude Code, or a human
developer. Treat committed repository files as the durable source of
truth. Do not rely on prior chat sessions or machine-local memory.

## Required reading

Before planning or editing, read:

1. `CLAUDE.md`
2. `docs/architecture/03-final-errata-patch.md`
3. `docs/architecture/04-architecture-handoff-manifest.md`
4. `docs/architecture/02-pass-2-baseline-consolidated-final.md`
5. `docs/architecture/01-approved-pass-1-baseline.md`
6. `docs/architecture/05-claude-project-handoff.md`
7. All accepted ADRs, currently:
   - `docs/architecture/06-adr-profile-provisioning.md`
8. The relevant implementation, tests, migrations, and README files.

## Precedence

Canonical architecture precedence:

1. `03-final-errata-patch.md`
2. `04-architecture-handoff-manifest.md`
3. `02-pass-2-baseline-consolidated-final.md`
4. `01-approved-pass-1-baseline.md`

Document 05 is a handoff summary and cannot override documents 01–04.

Accepted ADRs refine unresolved implementation decisions but cannot
override canonical documents 01–04.

## Current completed milestones

- Phase 1 database contract and Batch D: complete, 165/165.
- Phase 2 Step 1 FastAPI foundation: complete.
- Phase 2 Step 2 JWT-backed ownership context: complete.
- U11 / Step 2.5 profile provisioning: resolved and complete.
- Profile provisioning is defined by ADR 06.

## Security invariants

- FastAPI is the sole application writer.
- The backend connects as `fretvision_app`, which has `BYPASSRLS`.
- Backend ownership derives only from verified JWT `sub` through
  `AuthenticatedActor.user_id`.
- Never derive ownership from request-body `user_id`, `owner_id`,
  `profile_id`, or similar fields.
- Keep identity separate from request DTOs.
- Do not log tokens, credentials, DSNs, raw JWT claims, or secrets.

## Database rules

- Use raw asyncpg.
- Use explicit application transactions.
- SQL belongs in repository modules.
- Repositories receive an existing `asyncpg.Connection`.
- Direct PostgreSQL or Supavisor session mode only.
- Transaction pooling with prepared statements is forbidden.
- Do not change migrations, grants, RLS, triggers, seeds, pgTAP tests,
  scripts, or `supabase/config.toml` unless an actual contradiction is
  discovered and reported before editing.

## Workflow

- Check the current Git branch and working tree before working.
- For substantial work, produce a complete plan before editing.
- Wait for user approval when requested.
- Do not commit, push, merge, reset, delete files, or modify Git history
  unless explicitly instructed.
- Keep changes inside the requested scope.
- Run the documented formatter, type checker, and tests.
- Report changed files, commands run, results, and unresolved issues.
## Durable project status and handoff

The changing project status is maintained in:

`docs/PROJECT_STATUS.md`

Before planning or editing:

1. Read `docs/PROJECT_STATUS.md`.
2. Verify it against Git history, current code, and tests.
3. Report inconsistencies before changing files.
4. Treat committed implementation and passing tests as stronger evidence
   than an unverified status statement.

After completing and verifying a task:

1. Update `docs/PROJECT_STATUS.md` in the same branch and pull request.
2. Move the task into the completed section only after verification.
3. Record exact lint, type-check, unit-test, integration-test, and
   database-test results.
4. Record accepted architectural decisions and their ADR paths.
5. Record unresolved blockers without inventing resolutions.
6. Set the exact next task and recommended branch name.
7. Never include credentials, tokens, passwords, DSNs, or machine-local
   paths containing secrets.
8. Do not commit, push, merge, or modify Git history unless explicitly
   instructed.

Before finishing, explicitly report whether
`docs/PROJECT_STATUS.md` was updated.