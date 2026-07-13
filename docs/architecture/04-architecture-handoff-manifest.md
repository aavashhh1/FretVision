# FretVision — Architecture Handoff Manifest

**Status:** Pass 2 approved as binding implementation baseline. Precedence, highest first: (1) Final Errata Patch, (2) Pass 2 Consolidated Final, (3) Pass 1 Baseline + amendments, (4) original brief.

**Errata note:** The Final Errata Patch is a **delta** expressed as `ALTER`/`DROP`/backfill against an already-built schema. It **must not ship as sequential alters.** Before implementation, fold every errata item into **clean fresh-database migrations** so a from-scratch `supabase db reset` produces the final state directly (tables born with the corrected constraints, no `chk_no_born_published`, no `CREATE ROLE`, `instrument_id_snapshot` present from creation).

## 1. Technology & Transaction Decisions

Frontend Next.js + TS on Vercel. Backend FastAPI modular monolith, multi-stage Docker, containerized alone. Data/Auth Supabase (Postgres, Auth, RLS, migrations). CV: MediaPipe Hands + OpenCV.js in-browser; raw video never leaves device. CI GitHub Actions; structured JSON logs + request IDs; health/readiness endpoints.

**Transaction owner: FastAPI.** Direct PostgreSQL via `DATABASE_URL` using **asyncpg with explicit transactions**. Command RPC functions are removed. **Supavisor session mode** (or direct connection); **never transaction-pooler mode with prepared statements enabled.** Idempotency orchestration, sample aggregation, coverage calculation, and command workflow live in FastAPI application/domain layers. Postgres holds constraints + narrow triggers for hard invariants only.

**Credentials are distinct and non-interchangeable:** browser = publishable key + user JWT; FastAPI JWT verification = JWKS (asymmetric preferred; HS256/legacy anon/service_role are compatibility paths only); FastAPI DB = `DATABASE_URL` (dedicated role, not a Supabase API key); `SUPABASE_SECRET_KEY` only if FastAPI calls privileged Supabase HTTP APIs.

## 2. Entities & Relationships

Catalog: `instruments` (string_count = 6) → `exercises` (also → `lessons`) → `exercise_revisions` (immutable once published; carries `title_snapshot`, `instructions`, `accuracy_metric_version`, `calibration_method`, `instrument_id_snapshot`) → `target_position_revisions` → `target_string_actions` (one row per string 1–6; action ∈ fretted/open/muted/ignored).

User-owned: `auth.users` → `profiles` (1:1); `auth.users` → `sessions` (1:N). `sessions` → `session_samples` (1:N); `sessions` → `session_metrics` (0..1, completed only); `session_metrics` → `session_invalid_reason_counts` (1:N). `auth.users` → `idempotency_records` (1:N).

Structural: `sessions` composite FK `(exercise_revision_id, target_position_revision_id)` → `target_position_revisions(exercise_revision_id, id)` guarantees target belongs to exercise revision. **No `attempts` entity** (one session = one continuous practice period against one immutable revision pair).

## 3. Trust & Authorization Boundaries

Raw webcam video and per-frame landmarks stay on-device. Only derived interval samples + aggregates cross the wire. Client-supplied scores are **structurally validated, never physically verified** — fabricated self-consistent scores accepted per portfolio threat model.

Writes: FastAPI-only, as role `fretvision_app` (BYPASSRLS), ownership derived **solely from JWT `sub`**, never from request body. Reproducibility fields (`fretting_hand_snapshot`, `accuracy_metric_version`, `calibration_method`) copied server-side from profile/revision at start.

Reads: browser → Supabase Data API under RLS with user JWT (own profile/sessions/samples/metrics; published catalog; `security_invoker` analytics views). `idempotency_records` has no client grant. `anon` has no access. Catalog authoring is migration/admin-only.

## 4. SQL-Enforced vs FastAPI-Enforced Guarantees

**SQL-enforced (hold regardless of app code):** composite revision FK; `uq_session_seq`; string-action shape; one action per target/string; valid-sample ⇒ accuracy+confidence non-null; lifecycle-transition legality; new session born `created` with NULL activation/completion/duration/scoring; no sample insert/delete/modify on terminal sessions, no session_id/seq mutation; metrics-row ⇒ completed; at-most-one metrics row (PK); completed ⇒ metrics row at commit (deferred); completed session cannot lose metrics (delete-block); scoring_status domain by lifecycle; accuracy nullity vs valid count (NULL-safe); sync_delay ≥ 0; idempotency domain constraints + `uq_idem`; `processing` ⇒ NULL response fields / `completed` ⇒ non-null; published-subtree immutability (OLD+NEW parent); publish-time completeness (title/instructions non-empty, six-string instrument, instrument-snapshot match, ≥1 target, six string rows each); `string_count = 6`; instrument_id_snapshot FK.

**FastAPI-enforced:** JWKS JWT verification (issuer/audience); ownership from `sub`; payload schema + 64 KB size + offline chunking; interval band; zero-based full contiguity before completion; server-copy of reproducibility fields; deterministic aggregation (expected/effective_valid/ratio/coverage/scoring per §5 of Consolidated Final); request_hash; error envelope + status mapping.

**FastAPI transaction guarantees:** idempotency reservation + side effect in one transaction; atomic completion + metric insertion; aggregate from one consistent snapshot; rollback of both side effect and reservation on failure (no persisted `failed` state); concurrent same-key serialization on `uq_idem`, duplicate returns stored response after winner commits; reason-count sum = submitted − valid (verified by deferred trigger).

## 5. Superseded Decisions (must not reappear)

PostgreSQL command RPCs (`start_session`/`ingest_batch`/`complete_session`/`abandon_session`) and any claim they enforce behavior. "Single INSERT active" session-start alternative. `positions` JSONB and `invalid_reason_counts` JSONB (both normalized). `target_finger_positions` model (replaced by `target_string_actions`). `client_ts_ms` name (now `interval_end_offset_ms`). `idempotency_keys` session-only table (now user-scoped `idempotency_records`). Persisted `failed` idem state. `chk_no_born_published` tautology. `CREATE ROLE ... PASSWORD` in migrations. `GRANT ... ON ALL TABLES` to app role. Alphabetical trigger-order rename/explanation. CORS/non-root claimed as service-role-leak mitigation. `202` for synchronous batch (use `200`). Fixed per-row byte / 36 MB storage figures. `instruments.string_count` 4–12. Transaction-pooler-with-prepared-statements. Coverage from `completed_at − activated_at` (use `active_duration_ms`).

## 6. Required Repository Documents & Migrations

Docs (`docs/`): ADRs (transaction-owner = FastAPI; no-attempt-tier; six-string MVP; manual-4pt calibration); threat model (accepted fabricated-score risk); Accuracy Metric v1 spec; this manifest.

Migrations (`db/migrations/`, fresh-DB, errata folded in): (a) extensions + enums; (b) catalog tables + constraints; (c) user-owned tables + constraints; (d) triggers/functions (transition, born-created, terminal-sample lock, metrics gating/protection, deferred completed-needs-metrics + reason-count sum, published-subtree freeze, validate_publish with instrument-snapshot match); (e) `security_invoker` views; (f) least-privilege grants (assume role exists) + RLS policies; (g) catalog seed (author draft → publish → freeze). Seed CI validates apply-clean + RLS + immutability.

## 7. Secure Bootstrap for `fretvision_app`

Outside version control, before migration grants run: create role with `LOGIN`, strong password, `BYPASSRLS`; store password only inside `DATABASE_URL` in the backend secret store (never a migration, never logs). Grant `USAGE` on schema. Migration file (f) then applies the explicit least-privilege table grants (DML on user/session/idempotency tables; SELECT on catalog + views). Rotate password on schedule; restrict who can read the secret store; enable CI secret scanning. `instrument_id_snapshot` NOT NULL promotion requires its backfill to run first — enforce ordering within the fresh migration (column born with server-populated value at seed, so no live backfill in a clean build).

## 8. Remaining UNVERIFIED Pre-Deployment Checks

Supabase free-tier DB size / MAU / pause-on-inactivity; pg_cron availability for the 30-day `session_samples` purge (fallback: scheduled GitHub Actions workflow → authenticated purge endpoint); JWKS URL + expected issuer/audience for the actual project signing config; host connection-mode support (Supavisor session vs direct; transaction pooler forbidden with prepared statements); Render free-tier sleep/hours/build-minutes (primary) and Fly.io allowance (fallback); Vercel Hobby non-commercial terms; GitHub Actions free minutes. Verify each against first-party docs; record source + date; never ship fabricated quota numbers.

## 9. Recommended Implementation Order

1. Fold errata into fresh migrations; apply clean to Supabase CLI local stack; pass SQL checklist (constraints, immutability, grants, RLS).
2. Bootstrap `fretvision_app`; wire `DATABASE_URL` + JWKS verification; health/readiness + structured logging.
3. FastAPI write path: JWT + ownership dependency; the four transactional commands (start → batch → complete → abandon) with idempotency algorithm; integration checklist I1–I6.
4. Deterministic aggregation + coverage/scoring in domain layer; unit tests.
5. Direct-read analytics under RLS; `security_invoker` view isolation tests.
6. Browser CV: MediaPipe pipeline, manual 4-point calibration → homography, canonicalization, per-sample scoring, decoupled overlay, local batch buffer, offline chunked upload.
7. Degraded modes (camera-denied, WASM-fail, offline).
8. CI wiring (lint/test/migration-validate/Docker build/deploy); purge job; pre-deploy UNVERIFIED verification pass; latency-budget check on baseline device.

Steps 1–5 (contract + data integrity) precede 6–7 (CV) so the trust boundary is provable before client scores exist. This manifest is the binding handoff; no further architecture review or SQL in this conversation.