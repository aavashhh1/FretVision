# FretVision — Database Verification Harness (Batch D)

pgTAP suites covering the SQL guarantees the architecture documents classify as
**SQL-enforced**. Nothing here tests FastAPI, the browser, or any behaviour the
guarantee ledger assigns to the application layer.

## Status warning

**Migrations 0001–0007 have not yet been demonstrated green against a live local
Supabase stack.** This harness is written against the migration text, not against
a proven-running database. Migration 0006 revokes `USAGE ON SCHEMA public` from
`PUBLIC` and `anon`. That revocation is deliberate — anonymous Data API access is
not an MVP requirement — but its interaction with the Supabase local stack's own
service roles is **unverified**.

The runners' preflight exists to catch that. If preflight step 5, 6, 7, or 8
fails, **migration 0006 requires revision**. Do not edit these tests to work
around it.

## Layout

    supabase/tests/database/
      001_schema_invariants.test.sql
      002_catalog_immutability.test.sql
      003_lifecycle_and_metrics.test.sql
      004_rls_isolation.test.sql
      005_client_privileges.test.sql
      006_app_role_privileges.test.sql

    scripts/
      run_db_tests.sh
      run_db_tests.ps1

Every file opens a transaction, creates pgTAP in the `extensions` schema,
declares an exact `plan(n)`, calls `finish()`, and `ROLLBACK`s. **No test leaves
a row behind.** The 0007 seed is never mutated.

## Plans and coverage

| File | Plan | Phase | Covers |
|---|---|---|---|
| 001 | **32** | 1 | `string_count = 6`; `chk_action_shape` (NULL-safe fretted / open / muted / ignored); `uq_tsa_string`; composite `fk_revision_pair`; `declared_interval_ms` band; `sync_delay_ms ≥ 0`; `uq_session_seq`; `chk_valid_reason`; **`chk_accuracy_nullity` both branches**; **`chk_state_response` both branches** |
| 002 | **22** | 1 | `trg_validate_publish` (empty title, whitespace instructions, no target, five-row target, snapshot mismatch); successful publish; `trg_block_published_er`; `trg_freeze_tpr` and `trg_freeze_tsa` including OLD-side and NEW-side moves; seed intact |
| 003 | **28** | 1 | `trg_session_born_created`; legal and illegal transitions; terminal-session sample lock; `session_id` / `seq` immutability; `trg_metrics_only_completed`; deferred `completed_needs_metrics`; deferred `reason_counts_sum`; `protect_completed_metrics`; abandonment; user-delete cascade |
| 004 | **22** | 1 | Owner-only RLS on `profiles` / `sessions` / `session_samples` / `session_metrics` / `session_invalid_reason_counts`; `security_invoker` view isolation; published-only catalog visibility; `idempotency_records` denial |
| 005 | **34** | 1 | `authenticated` write-denial across every relation; `anon` and `PUBLIC` privilege surface; function `EXECUTE` surface; sequence surface; RLS `ENABLE` + `FORCE`; `security_invoker` view options; policy surface |
| 006 | **27** | 2 | `fretvision_app` role attributes and the complete grant surface |

Total: **165 assertions.**

## Phase separation

Phases are **genuinely separate command invocations**, not a single pass with a
warning:

| Phase | Files | Prerequisite | Invocation |
|---|---|---|---|
| 1 | 001–005 | `supabase db reset` only | `supabase test db <five explicit paths>` |
| GATE | — | `fretvision_app` must exist | admin query against `pg_catalog.pg_roles` |
| 2 | 006 | `bootstrap_role.sql` **and** `grant_fretvision_app.sql` | `supabase test db <one explicit path>` |

`supabase test db` accepts explicit file paths, so phase 1 runs and passes before
the gate is evaluated and phase 2 is dispatched. A phase-1 failure never reaches
phase 2. An absent `fretvision_app` fails at the gate with an actionable message,
not as a cryptic privilege error inside 006.

006 additionally raises its own `PHASE 2 PREREQUISITE UNMET` exception before
declaring its plan, so running it out of order under a bare `psql` also fails
clearly.

## Application role is ratified, not configurable

`fretvision_app` is the **fixed Phase 1 application-role name**. Test 006 hard-codes
it because it verifies that specific approved role, not an arbitrary one. Both
runners therefore **reject** a `FRETVISION_APP_ROLE` that differs from
`fretvision_app` rather than silently honouring it. Unset the variable, or set it
to `fretvision_app`.

(`reset_local.sh` / `reset_local.ps1` retain their own override for other
purposes; the test runners do not.)

## How RLS is simulated

No GoTrue signup. No HTTP. Test 004:

1. Inserts two minimal `auth.users` rows as the admin connection, with
   deterministic UUIDs and `@fretvision.invalid` addresses.
2. Seeds owned fixtures for both.
3. `set local role authenticated;`
4. Sets **both** `request.jwt.claim.sub` and `request.jwt.claims`.
5. Asserts, switches the claim to the second UUID, asserts again.
6. `ROLLBACK`.

**Why both GUCs.** `auth.uid()` resolves through `request.jwt.claim.sub` on some
Supabase releases and through `request.jwt.claims ->> 'sub'` on others. Setting
only one risks `auth.uid()` returning `NULL` — which would make every *"User B
cannot read A's rows"* assertion pass **vacuously**. Test 004 therefore sets both
and opens each impersonation with a guard asserting `auth.uid()` resolves to the
expected UUID. A `NULL` uid fails the suite loudly instead of producing a green
run that proves nothing.

## Why 006 uses introspection rather than a second connection

`supabase test db` connects as the admin role and offers no way to re-connect as
`fretvision_app` mid-suite. Test 006 therefore asserts the entire grant surface
through `pg_catalog` and `has_*_privilege()`, which is role-agnostic and
authoritative: `has_table_privilege('fretvision_app', …)` answers the same
question a real connection would. This also keeps the role's password out of the
harness entirely — 006 never needs it.

## Deferred-constraint assertions

Deferred constraint triggers (`completed_needs_metrics`, `reason_counts_sum`,
`protect_completed_metrics`) are exercised by running the DML as a **bare
statement** and then asserting **only** `set constraints all immediate` inside
the pgTAP call:
