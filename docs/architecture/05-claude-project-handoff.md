# FretVision — Architecture Handoff (Phase 1 → Phase 2)

**Document ID:** `docs/architecture/05-claude-project-handoff.md`
**Status:** Repository-ready handoff. Records only decisions already made and verified implementation state; introduces no new architecture.

## 0. Standing of this document

**Precedence (highest first):**

1. `03-final-errata-patch.md`
2. `04-architecture-handoff-manifest.md`
3. `02-pass-2-baseline-consolidated-final.md`
4. `01-approved-pass-1-baseline.md` + amendments
5. Original brief

This document sits **below** the canonical chain above. It **records**, **summarizes**, and **cross-references**; it does not override any canonical source.

Where this document records an implementation detail absent from 01–04 (§10), that detail must not silently change architecture. If a conflict is found, report it and resolve it through a new errata/ADR rather than changing code locally.

**Status vocabulary used throughout:**

| Tag | Meaning |
|---|---|
| **RATIFIED** | Approved by the canonical architecture documents. Locked unless a contradiction prevents a valid implementation. |
| **IMPLEMENTED** | A repository artifact exists. |
| **VERIFIED** | The artifact has been executed successfully against the local Supabase stack and the evidence is recorded in the repository workflow. |
| **PLANNED** | Ratified in principle; no implementation artifact yet. |
| **UNRESOLVED** | Genuinely open and requires a decision or first-party verification. |

## 1. Confirmed architecture decisions — RATIFIED

| Area | Decision |
|---|---|
| Shape | Modular monolith. Next.js + TypeScript (Vercel) → FastAPI (Docker, containerized alone) → Supabase Postgres. |
| Transaction owner | **FastAPI.** Direct PostgreSQL via `DATABASE_URL`, **asyncpg with explicit transactions.** Command RPC functions are removed and must not return. |
| Connection mode | Supavisor **session** mode, or direct connection. **Transaction-pooler mode with prepared statements is forbidden.** |
| Postgres role | Constraints + narrow triggers for **hard invariants only.** Orchestration, aggregation, idempotency, and coverage logic live in FastAPI. |
| CV | MediaPipe Hands + OpenCV.js, **in-browser**. Manual four-point calibration (nut/low-E, nut/high-E, 12th/low-E, 12th/high-E) → image-to-canonical-fretboard homography. |
| Transport | REST. No WebSockets, SSE, or WebRTC in the MVP practice loop. |
| Trust | Client-supplied scores are **structurally validated, never physically verified.** Fabricated self-consistent scores are an **accepted risk** per the portfolio threat model. |
| Domain model | No `attempts` entity. One session = one continuous practice period against one immutable `(exercise_revision, target_position_revision)` pair. |
| Six-string MVP | `instruments.string_count = 6`, enforced by CHECK. |
| Ops | GitHub Actions CI; structured JSON logs + request IDs; health/readiness endpoints. |

### Credentials — four distinct, non-interchangeable secrets

| Consumer | Credential |
|---|---|
| Browser | Publishable key + user JWT |
| FastAPI → JWT verification | **JWKS** (asymmetric preferred; HS256 / legacy `anon` / `service_role` are compatibility paths only) |
| FastAPI → DB | `DATABASE_URL` (role `fretvision_app`) — **not** a Supabase API key |
| FastAPI → privileged Supabase HTTP APIs | `SUPABASE_SECRET_KEY`, **only if** such a call is actually made |

---

## 2. Ratified constraints and non-goals

### Hard constraints — RATIFIED

- Raw webcam video and full per-frame landmarks **never leave the device** and are never persisted.
- Only derived interval samples and aggregates cross the wire.
- All writes are FastAPI-only. Ownership derives **solely from the JWT `sub`**, never from a request body.
- Free-tier or local-only infrastructure.
- Reproducibility fields (`fretting_hand_snapshot`, `accuracy_metric_version`, `calibration_method`) are **copied server-side** at session start from `profiles` / `exercise_revisions`, ignoring any client-supplied value.

### Non-goals — RATIFIED

Microservices. Kubernetes. GPU infrastructure. Message brokers. Paid mandatory services. Audio correctness. Capo support. Frets beyond 1–12. Multiple guitars in frame. Attempt tier.

### Superseded — must not reappear

Postgres command RPCs (`start_session` / `ingest_batch` / `complete_session` / `abandon_session`) and any claim that they enforce behavior · "single INSERT active" session start · `positions` JSONB · `invalid_reason_counts` JSONB · `target_finger_positions` · `client_ts_ms` (now `interval_end_offset_ms`) · session-scoped `idempotency_keys` (now user-scoped `idempotency_records`) · persisted `failed` idempotency state · `chk_no_born_published` · `CREATE ROLE ... PASSWORD` in migrations · `GRANT ... ON ALL TABLES` to the app role · alphabetical trigger-order reasoning · CORS/non-root framed as service-role-leak mitigation · `202` for a synchronous batch (use `200`) · fixed per-row-byte / 36 MB storage figures · `string_count` 4–12 · transaction-pooler-with-prepared-statements · coverage derived from `completed_at − activated_at` (use `active_duration_ms`).

---

## 3. Current milestone

**Phase 1 — Canonical Artifacts and Batch D: IMPLEMENTED AND VERIFIED.**

Phase 1 scope was limited to architecture documentation, Supabase migrations, the SQL/RLS/invariant test harness, secure bootstrap/reset scripts, environment examples, and repository setup. FastAPI routes, frontend implementation, browser CV, and deployment remain outside Phase 1.

### Verification evidence

The full local workflow has been executed successfully against the live local Supabase stack:

- Migrations `0001–0007`: applied successfully
- Local administrator bootstrap: `supabase_admin`
- `fretvision_app`: created successfully
- Least-privilege grants: applied successfully
- Preflight checks: **8/8 passed**
- Phase 1 pgTAP assertions: **138 passed**
- Phase 2 pgTAP assertions: **27 passed**
- Total: **165/165 passed**
- Final result: `ALL BATCH D TESTS PASSED`

The prior risk around migration `0006` revoking `USAGE ON SCHEMA public` from `PUBLIC` and `anon` has been tested locally. The authenticated role can read the published catalog and query both `security_invoker` views, while `anon` does not retain schema usage.

### Artifacts present

| Artifact | Path | Status |
|---|---|---|
| Migrations 0001–0007 | `supabase/migrations/` | IMPLEMENTED, VERIFIED |
| Trigger set and hard invariants | `supabase/migrations/…0004_triggers.sql` | IMPLEMENTED, VERIFIED |
| `security_invoker` views | `…0005_views.sql` | IMPLEMENTED, VERIFIED |
| Client grants + RLS | `…0006_client_grants_rls.sql` | IMPLEMENTED, VERIFIED |
| Catalog seed | `…0007_seed_catalog.sql` | IMPLEMENTED, VERIFIED |
| pgTAP suite, 6 files / **165 assertions** | `supabase/tests/database/001–006` | IMPLEMENTED, VERIFIED |
| Test runners | `scripts/run_db_tests.{sh,ps1}` | IMPLEMENTED, VERIFIED on Windows PowerShell |
| Role bootstrap + grants | `scripts/bootstrap_role.sql`, `scripts/grant_fretvision_app.sql` | IMPLEMENTED, VERIFIED |
| Local reset | `scripts/reset_local.{sh,ps1}` | IMPLEMENTED, VERIFIED on Windows PowerShell |

### pgTAP coverage

| File | Plan | Phase | Covers |
|---|---:|:---:|---|
| 001 schema invariants | 32 | 1 | `string_count=6`; NULL-safe checks; composite revision pair FK; interval and sequence constraints; sample validity and state-response invariants |
| 002 catalog immutability | 22 | 1 | Publish validation; revision and subtree immutability; OLD/NEW parent movement protection; seed integrity |
| 003 lifecycle & metrics | 28 | 1 | Born-created rules; lifecycle transitions; terminal sample lock; sample identity immutability; metrics gating; deferred completion and reason-count constraints; abandonment; cascade |
| 004 RLS isolation | 22 | 1 | Owner-only RLS across user tables; view isolation; published-only catalog; idempotency-record denial |
| 005 client privileges | 34 | 1 | Authenticated write denial; anon/PUBLIC surface; function and sequence surface; RLS enable/force; policy surface |
| 006 app-role privileges | 27 | 2 | `fretvision_app` attributes and complete least-privilege grant surface |

Every test file opens a transaction and rolls it back. Test 003 uses isolated PL/pgSQL subtransactions for deferred-trigger scenarios so pgTAP bookkeeping is not rolled back.

**Phase 2 is now open.**

## 4. Component responsibilities

### Frontend (Next.js + TS) — PLANNED

Auth via Supabase (publishable key + user JWT) · camera capture · MediaPipe Hands + OpenCV.js pipeline · manual 4-point calibration → homography · canonicalization of mirroring, handedness, rotation, and fretboard orientation · per-interval scoring · overlay rendering **decoupled from the scoring loop** · local batch buffer · offline chunked upload · degraded modes (camera-denied, WASM-fail, offline) · **direct reads** from the Supabase Data API under RLS · accessible, responsive UI.

The client selects **one** sampling interval in **[2000, 5000] ms** at session start. It is **fixed for the whole session.**

### Backend (FastAPI) — PLANNED

Sole writer. Enforces, per the ratified guarantee ledger:

- JWKS JWT verification (issuer + audience)
- Ownership from `sub` **only**
- Payload schema + **64 KB** size limit + offline chunking
- Interval band enforcement
- **Zero-based full contiguity** of `seq` before completion is permitted
- Server-copy of the three reproducibility fields
- Deterministic aggregation (§5 below)
- `request_hash` computation
- Error envelope + status mapping

Connects as `fretvision_app`, which holds `BYPASSRLS` — so **ownership is an application-layer obligation, not an RLS one, on the write path.** This is the single most important thing for a Phase 2 implementer to internalize.

### Database (Supabase Postgres) — IMPLEMENTED

Holds only hard invariants. SQL-enforced, independent of application code:

composite revision FK · `uq_session_seq` · `chk_action_shape` · one action row per target/string · valid-sample ⇒ accuracy + confidence non-null · lifecycle-transition legality · session born `created` with NULL activation/completion/duration/sync/scoring · no sample insert/delete/modify on terminal sessions · no `session_id`/`seq` mutation · metrics row ⇒ session completed · at most one metrics row (PK) · **completed ⇒ metrics row at commit** (deferred) · completed session cannot lose its metrics row (delete-block) · `scoring_status` domain by lifecycle · NULL-safe accuracy nullity · `sync_delay_ms ≥ 0` · idempotency domain constraints + `uq_idem` · `processing` ⇒ NULL response fields, `completed` ⇒ non-null · published-subtree immutability (OLD **and** NEW parent) · publish-time completeness · `string_count = 6` · `instrument_id_snapshot` FK.

### Auth (Supabase) — RATIFIED / partially IMPLEMENTED

Supabase Auth issues the JWT. Browser reads under RLS with it. FastAPI verifies it via JWKS. `anon` has **no access**. Catalog authoring is **migration/admin-only** — there is no authoring API and none is planned for the MVP.

### CV (browser) — PLANNED

Scoring operates on **fretboard-relative canonical coordinates, never raw image coordinates.** Calibration is valid only while camera and guitar remain sufficiently static. Per interval the client emits exactly one record:

- **Valid** → carries `placement_accuracy` + `confidence`
- **Invalid** → carries an `invalid_reason`, **no** accuracy

Invalid reasons: low confidence · occlusion · hand or fretboard out of frame · missing fretboard localization · wrong-hand detection. **Invalid intervals still occupy a sequence position and are never treated as zero-accuracy samples.**

---

## 5. Session lifecycle and revision semantics

### Lifecycle — RATIFIED, IMPLEMENTED

```
created ──▶ active ──▶ completed
                └────▶ abandoned
```

Only these three transitions are legal. All others raise `check_violation` (SQLSTATE `23514`).

| State | Invariant |
|---|---|
| `created` | Born here. `activated_at`, `active_duration_ms`, `ended_at_client`, `completion_received_at`, `sync_delay_ms`, `scoring_status` **all NULL**. |
| `active` | `activated_at` non-null (server-generated). Samples may be inserted. |
| `completed` | Timing fields non-null; **exactly one** `session_metrics` row at commit (deferred trigger); `scoring_status` non-null and server-derived. |
| `abandoned` | `scoring_status = 'insufficient_coverage'`, forced by CHECK. **No metrics row.** |

Session start is **`INSERT created` → `UPDATE active`, inside one transaction**, with `activated_at` server-generated. The single-insert-active alternative is **withdrawn**.

Terminal sessions are frozen: no sample insert, delete, or modification; `session_id` and `seq` are immutable on any sample.

### Timing model — RATIFIED

| Field | Source | Trust |
|---|---|---|
| `activated_at` | **Server** | Authoritative |
| `active_duration_ms` | Client monotonic timer | Structurally validated, **physically untrusted** |
| `ended_at_client` | Client wall clock | Sanity-check / display only |
| `completion_received_at` | **Server** | Authoritative receipt time |
| `sync_delay_ms` | Derived | Diagnostic. **Never** counted as practice duration or coverage. Nullable. |

Bounds: `active_duration_ms > 0`; MVP maximum **90 minutes**; declared interval in **[2000, 5000] ms**, immutable mid-session.

### Deterministic aggregation — RATIFIED

```
expected_sample_count  = floor(active_duration_ms / declared_interval_ms)
submitted_sample_count = count(samples)
valid_sample_count     = count(samples where is_valid)
effective_valid_count  = min(valid_sample_count, expected_sample_count)
valid_sample_ratio     = expected_sample_count = 0 ? 0
                       : effective_valid_count / expected_sample_count
coverage_duration_ms   = effective_valid_count * declared_interval_ms
placement_accuracy     = valid_sample_count = 0 ? NULL : mean(accuracy of valid)
confidence_mean        = valid_sample_count = 0 ? NULL : mean(confidence of valid)
scoring_status         = (valid_sample_ratio >= 0.60
                          AND coverage_duration_ms >= 120000)
                         ? 'scored' : 'insufficient_coverage'
```

An incomplete trailing interval contributes **no sample and no coverage** — `floor` excludes it. `effective_valid_count` caps over-sampling so the ratio never exceeds 1. **`scoring_status` is always derived server-side, never client-supplied.**

Accuracy and coverage are **deliberately separate**: high accuracy over few valid samples does **not** imply a scored session.

### Revision semantics — RATIFIED

`exercise_revisions` are **immutable once published.** A revision carries `title_snapshot`, `instructions`, `accuracy_metric_version`, `calibration_method`, and `instrument_id_snapshot`.

Publish-time validation (`trg_validate_publish`) rejects: empty/whitespace `title_snapshot` or `instructions` · instrument snapshot ≠ `exercises.instrument_id` · non-six-string instrument · zero targets · any target lacking exactly six string rows. On success it sets `published_at` if NULL.

Post-publish, the whole subtree freezes: `exercise_revisions`, `target_position_revisions`, and `target_string_actions` all reject writes — including an UPDATE that moves a row **between** a published and unpublished parent (both OLD and NEW parents are checked).

**`instrument_id_snapshot` is a point-in-time check at publish.** The parent `exercises.instrument_id` may change afterward; **the snapshot is the authoritative historical value used for reproduction.** This is intentional, not a bug.

Sessions bind to a revision pair via a **composite FK** — `(exercise_revision_id, target_position_revision_id)` → `target_position_revisions(exercise_revision_id, id)` — which structurally guarantees the target belongs to that exercise revision. There is no way to construct a session pointing at a mismatched pair.

### Idempotency — RATIFIED

User-scoped `idempotency_records`, keyed `(user_id, operation, idempotency_key)` = `uq_idem`. Operations: `start_session`, `ingest_batch`, `complete_session`, `abandon_session`.

```
BEGIN;
  INSERT idempotency_records(... state='processing' ...)
    ON CONFLICT (user_id, operation, idempotency_key) DO NOTHING;

  IF 0 rows inserted:
     SELECT ... FOR UPDATE;              -- serializes concurrent duplicates
     IF state='completed' AND hash matches -> ROLLBACK; return stored (status, body)
     IF hash differs                       -> ROLLBACK; return 409 idempotency_key_conflict
     -- 'processing' is only visible while a concurrent txn holds the lock;
     --  FOR UPDATE blocks until it commits ('completed') or rolls back (row vanishes)

  -- side effect (ownership from JWT sub, never from body)

  UPDATE idempotency_records SET state='completed', response_status=?, response_body=?;
COMMIT;   -- deferred triggers evaluated here
-- ANY error: ROLLBACK removes BOTH the side effect AND the reservation.
```

**No `failed` state is ever persisted.** Aggregates come from a **single consistent snapshot** — the sample scan and the metrics insert occur in the same transaction, and samples are already locked out of terminal sessions by trigger.

---

## 6. Security and RLS boundaries

### Write path

FastAPI only, as `fretvision_app` (`LOGIN`, `BYPASSRLS`). **`BYPASSRLS` means RLS provides zero protection on the write path.** Ownership is enforced in application code from the JWT `sub`, and nowhere else. A Phase 2 bug that reads `user_id` from a request body is an **authorization vulnerability**, not a validation slip.

Grants to `fretvision_app` (from `scripts/grant_fretvision_app.sql`, **not** from a migration):

- **DML** on `profiles`, `sessions`, `session_samples`, `session_metrics`, `session_invalid_reason_counts`, `idempotency_records`
- **SELECT only** on the catalog tables and both views
- `USAGE` on schema `public`

No `GRANT ... ON ALL TABLES`. Ever.

### Read path

Browser → Supabase Data API under RLS with the user JWT.

| Relation | `authenticated` | `anon` |
|---|---|---|
| `profiles`, `sessions`, `session_samples`, `session_metrics`, `session_invalid_reason_counts` | SELECT, **owner rows only** | none |
| Catalog tables | SELECT, **published subtree only** (anchored on `exercise_revisions.published`) | none |
| `v_latest_published_revision`, `v_user_practice_summary` | SELECT, `security_invoker` | none |
| `idempotency_records` | **no grant at all** | none |

`session_samples`, `session_metrics`, and `session_invalid_reason_counts` carry **no `user_id` column** — ownership resolves *through* `sessions`. Catalog authoring is migration/admin-only.

Views are `security_invoker = true` so the caller's RLS applies rather than the definer's. `v_user_practice_summary.average_placement_accuracy` filters on **both** `lifecycle='completed'` **and** `scoring_status='scored'` — a thinly-covered session cannot inflate the average.

### Secret handling — RATIFIED, IMPLEMENTED

**No literal database password may appear in any SQL file, shell script, PowerShell script, migration, log, or committed configuration.** Passwords come from git-ignored environment variables or masked CI secrets. Admin credentials reach `psql` via `PGHOST`/`PGPORT`/`PGDATABASE`/`PGUSER` plus an **ephemeral `PGPASSFILE`** built and deleted at runtime — **never as a URI argument**, which would expose them in the process table.

The reset scripts build a transaction wrapper around `bootstrap_role.sql`. They send `BEGIN` and five `SET LOCAL` statements before transmitting the password-bearing GUC and bootstrap SQL:

| Setting | Suppresses |
|---|---|
| `log_statement = 'none'` | Statement text for `CREATE`/`ALTER ROLE ... PASSWORD` |
| `log_min_error_statement = 'panic'` | Statement text accompanying a failing role statement |
| `log_min_duration_statement = -1` | Slow-statement logging |
| `log_min_duration_sample = -1` | Sampled slow-statement logging |
| `log_transaction_sample_rate = 0` | Per-transaction sampling |

In local Docker mode, the scripts execute `psql` inside the Supabase database container and select the accessible superuser `supabase_admin`. In host-`psql` mode, they use discrete PG variables and an ephemeral `PGPASSFILE`.

**Scope limit:** this protects against standard PostgreSQL statement and duration logging. It does not claim coverage for `pgaudit`, other hooks, `pg_stat_statements`, proxies, external capture, or WAL. Verify those separately for non-local deployments.

`BEGIN` must precede `SET LOCAL`; this ordering is enforced by script construction and verified operationally, not by an in-SQL introspection guard.

### Threat model — accepted risks

A modified client can submit self-consistent fabricated scores. **This is accepted, explicitly, per the portfolio threat model.** The server validates structure and derives aggregates; it cannot and does not verify physical finger placement. Untrusted inputs: per-sample `placement_accuracy`, `confidence`, `is_valid`/`invalid_reason`; `active_duration_ms`; `ended_at_client`; client sample UUIDs; `interval_end_offset_ms`; `client_preview_metrics` (diagnostic, unpersisted).

---

## 7. Local vs hosted Supabase workflow

**`supabase/migrations/` is the only migration directory.** The `db/migrations/` path in the handoff manifest is **logical, not literal.** No sync script, no duplicate tree.

The migration chain **never references `fretvision_app`.** Role creation lives in `scripts/bootstrap_role.sql`; explicit privileges in `scripts/grant_fretvision_app.sql`. This is why the pgTAP suite is **phase-separated** rather than one pass:

| Phase | Files | Prerequisite |
|---|---|---|
| **1** | 001–005 | `supabase db reset` only |
| **GATE** | — | admin query: does `fretvision_app` exist in `pg_catalog.pg_roles`? |
| **2** | 006 | `bootstrap_role.sql` **and** `grant_fretvision_app.sql` have run |

`supabase test db` accepts explicit paths, so phase 1 runs and passes **before** the gate is evaluated. A phase-1 failure never reaches phase 2. An absent role fails at the gate with an actionable message, not a cryptic privilege error inside 006. Test 006 additionally raises `PHASE 2 PREREQUISITE UNMET` before declaring its plan, so running it out of order under bare `psql` also fails clearly.

### Local

```text
supabase start
supabase db reset                    # applies 0001–0007
scripts/bootstrap_role.sql           # creates fretvision_app (BYPASSRLS)
scripts/grant_fretvision_app.sql     # explicit least-privilege grants
scripts/run_db_tests.{sh,ps1}        # preflight → phase 1 → gate → phase 2
```

`reset_local.{sh,ps1}` wraps start, reset, bootstrap, and grants. On Windows, host `psql.exe` is optional: the verified fallback executes `psql` inside `supabase_db_<project_id>` and uses `supabase_admin` for privileged bootstrap.

`fretvision_app` is the ratified, non-configurable Phase 1 role name. Reset and test runners reject a differing `FRETVISION_APP_ROLE` override because test 006 verifies that exact approved role.

The harness checks the required PostgreSQL service directly. Optional local services such as imgproxy or the connection pooler may remain stopped without failing Batch D.

### RLS simulation in tests

No GoTrue signup, no HTTP. Test 004 inserts two `auth.users` rows as admin with deterministic UUIDs and `@fretvision.invalid` addresses, then `set local role authenticated` and sets **both** `request.jwt.claim.sub` **and** `request.jwt.claims`.

**Both GUCs, deliberately.** `auth.uid()` resolves through `request.jwt.claim.sub` on some Supabase releases and `request.jwt.claims ->> 'sub'` on others. Setting only one risks `auth.uid()` returning NULL — which would make every *"User B cannot read A's rows"* assertion pass **vacuously**. Each impersonation therefore opens with a guard asserting `auth.uid()` resolves to the expected UUID. A NULL uid **fails loudly** instead of producing a green run that proves nothing.

### Hosted

Same migration chain. Bootstrap and grants run **out of band** against the hosted DB, before the app connects. The password lives only inside `DATABASE_URL` in the backend secret store. Rotate on a schedule; restrict secret-store read access; enable CI secret scanning.

---

## 8. Open decisions — UNRESOLVED

### 8.1 Former Phase 1 blockers — RESOLVED

| Former item | Resolution |
|---|---|
| **U1 — migrations not proven against a live local stack** | **RESOLVED.** The full reset, bootstrap, preflight, and pgTAP workflow passed locally. |
| **U2 — migration 0006 schema-usage revocation might break the local stack** | **RESOLVED for the local stack.** Preflight steps 5–8 passed. Revalidate separately in hosted environments before deployment because hosted service-role behavior may differ. |
| Local role bootstrap required protected PostgreSQL settings | **RESOLVED.** Local Docker bootstrap uses accessible superuser `supabase_admin`; the restricted `postgres` role is not used for privileged bootstrap. |
| pgTAP savepoint bookkeeping in test 003 | **RESOLVED.** Stateful deferred-trigger cases use PL/pgSQL exception subtransactions rather than rolling back pgTAP assertions. |

### 8.2 Pre-deployment — verify against first-party sources and record source + date

Never ship a fabricated quota or platform-capability number.

| # | Item |
|---|---|
| **U3** | Supabase free tier: database size, MAU, and pause-on-inactivity behavior |
| **U4** | `pg_cron` availability for the 30-day `session_samples` purge. Fallback: scheduled GitHub Actions calling an authenticated purge endpoint |
| **U5** | JWKS URL and expected issuer/audience for the actual Supabase project signing configuration |
| **U6** | Hosted connection-mode support: Supavisor session mode or direct connection. Transaction-pooler mode with prepared statements remains forbidden |
| **U7** | Render free tier behavior and limits; Fly.io fallback allowance |
| **U8** | Vercel Hobby terms applicable to the intended use |
| **U9** | GitHub Actions included minutes and limits |

### 8.3 Genuinely undecided

| # | Item | Status |
|---|---|---|
| **U10** | Latency budget and baseline device for browser CV | UNRESOLVED |
| **U11** | Profile provisioning strategy: auth trigger, FastAPI upsert, or first-login flow | **RESOLVED** — FastAPI lazy, idempotent provisioning. See `06-adr-profile-provisioning.md`. The auth-trigger, Supabase Auth hook, browser-direct insert, client-only first-login, and service-role options are rejected. Provisioning creates defaults with `ON CONFLICT DO NOTHING` and never overwrites an existing `display_name` or `fretting_hand`; start-session defensively ensures the profile inside its own transaction; ownership comes only from the JWT `sub`. |
| **U12** | Reaper strategy for expired `idempotency_records` | UNRESOLVED |
| **U13** | Upgrade path for `accuracy_metric_version` beyond version 1 | UNRESOLVED |

## 9. Recommended Phase 2 sequence

Phase 1 has passed its gate. The next work should preserve that green baseline and implement the application layer without reopening approved database contracts.

| # | Step | Exit criterion |
|---:|---|---|
| **0 — DONE** | Canonical artifacts, migrations, bootstrap, grants, preflight, and Batch D verification | **165/165 assertions green** |
| **1** | Scaffold FastAPI; typed settings; `DATABASE_URL`; JWKS verification; health/readiness; structured JSON logs and request IDs | Readiness endpoint succeeds against the local database |
| **2** | JWT and ownership dependency. Ownership derives only from JWT `sub` | Unit tests prove body-supplied `user_id` is ignored |
| **3** | Implement start, ingest-batch, complete, and abandon commands with explicit asyncpg transactions and the approved idempotency algorithm | Integration checks I1–I4 pass |
| **4** | Implement deterministic aggregation and scoring in the domain layer | Integration checks I5–I6 pass; unit tests cover ratio cap, coverage cap, and NULL accuracy at zero valid samples |
| **5** | Implement direct-read analytics under RLS | View isolation holds with real JWT-backed requests |
| **6** | Resolve U10, then build browser CV: MediaPipe, calibration, homography, canonicalization, interval scoring, decoupled overlay, local buffering, offline chunking | Measured latency meets the ratified budget |
| **7** | Implement degraded modes: camera denied, WASM failure, offline | Each mode degrades visibly and predictably |
| **8** | Add CI, migration verification, Docker build, purge/reaper jobs, and deployment checks; resolve U3–U9 | No unverified deployment assumption remains |

**Integration checklist:**

- **I1** — start/batch/complete/abandon are atomic; an error rolls back both side effect and idempotency reservation
- **I2** — same key + same hash returns stored response; different hash returns `409`
- **I3** — concurrent same-key duplicate serializes on `uq_idem`
- **I4** — completion returns `422` until persisted sample sequence is zero-based and contiguous
- **I5** — aggregation matches §5 exactly; `scoring_status` is server-derived
- **I6** — reproducibility fields are copied server-side and request-supplied values are ignored

## 10. Decisions ratified in working sessions but absent from 01–04

Per §0, these are recorded implementation decisions and clarifications. They do not override the canonical documents.

| # | Decision | Standing |
|---|---|---|
| **C1** | `chk_action_shape` is NULL-safe; the `fretted` branch explicitly requires non-null fret/finger data because PostgreSQL CHECK constraints pass on NULL results. | Implements the intended hard invariant |
| **C2** | `supabase/migrations/` is the sole migration directory. `db/migrations/` in earlier planning was logical, not literal. | Clarification |
| **C3** | Batch B is implemented as one migration, `0004_triggers.sql`, containing all approved hard-invariant triggers. | Structural implementation choice |
| **C4** | Migration 0006 revokes `USAGE ON SCHEMA public` from `PUBLIC` and `anon`. | Verified against the local stack; revalidate in hosted deployment |
| **C5** | `average_placement_accuracy` includes only `completed` and `scored` sessions. | Preserves separation of accuracy and coverage |
| **C6** | Host `psql` mode uses discrete PG variables plus ephemeral `PGPASSFILE`; local Windows Docker fallback executes `psql` inside the Supabase DB container and auto-selects `supabase_admin` for privileged bootstrap. | Secret-handling implementation |
| **C7** | Logging-suppression claims are scoped to standard PostgreSQL logging and do not claim coverage for `pgaudit`, hooks, proxies, WAL, or external capture. | Security-scope clarification |
| **C8** | `fretvision_app` is fixed for Phase 1 verification. Reset and test runners reject a differing role override. | Harness discipline |
| **C9** | RLS simulation sets both `request.jwt.claim.sub` and `request.jwt.claims`, then asserts `auth.uid()` resolves correctly. | Prevents vacuous RLS tests |
| **C10** | BEFORE-row trigger expectations account for trigger execution occurring before unique-index evaluation. | pgTAP SQLSTATE correctness |
| **C11** | Deferred-trigger scenarios in test 003 use a `pg_temp` PL/pgSQL helper with exception subtransactions and a private sentinel exception. Explicit `SAVEPOINT ... ROLLBACK TO` is not used around pgTAP assertions because it rolls back pgTAP counters. | Verified harness pattern |
| **C12** | SQL uses empty search paths and full qualification where valid. Ordinary functions may be schema-qualified, but SQL syntactic constructs such as `COALESCE` must not be written as `pg_catalog.coalesce(...)`. | Corrected SQL convention |
| **C13** | Phase 1 scope is canonical artifacts only. FastAPI, frontend, CV, and deployment begin in Phase 2. | Milestone boundary |
| **C14** | Database verification checks required PostgreSQL availability directly. Optional local services such as imgproxy or the connection pooler are not required for Batch D. | Local harness behavior |
| **C15** | The local Supabase `postgres` role is insufficient for protected logging-parameter changes; privileged local bootstrap uses `supabase_admin`. | Verified local-stack behavior |

**Recommendation:** create a future canonical errata/ADR covering C1, C2, C4, C5, C7, C11, C12, C14, and C15. Phase 2 implementation may begin now because these are already represented in the verified executable artifacts; the documentation patch prevents future context loss.

## Appendix — precedence quick reference

```text
03-final-errata-patch.md                    ← highest
04-architecture-handoff-manifest.md
02-pass-2-baseline-consolidated-final.md
01-approved-pass-1-baseline.md + amendments
original brief
─────────────────────────────────────────
05-claude-project-handoff.md (this file)    ← records; never overrides
```

Report contradictions between this document, the canonical documents, and the verified executable artifacts. Do not resolve architectural contradictions silently in code.