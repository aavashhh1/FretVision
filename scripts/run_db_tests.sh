#!/usr/bin/env bash
# ============================================================
# scripts/run_db_tests.sh
# Batch D verification harness runner (Bash / macOS / Linux / WSL).
#
# PHASES ARE GENUINELY SEPARATE. `supabase test db` accepts explicit file
# paths, so phase 1 (001-005) and phase 2 (006) are two distinct
# invocations with a role-existence gate between them.
#
#   PREFLIGHT  supabase start; approved reset; health; grant-surface probes
#   PHASE 1    001-005          requires migrations 0001-0007 only
#   GATE       fretvision_app must exist
#   PHASE 2    006              requires bootstrap + grants
#
# Migrations 0001-0007 have NOT yet been demonstrated green against a live
# local stack. Preflight is FAIL-FAST and diagnostic: if migration 0006's
# schema-USAGE revocations break the authenticated Data API surface, this
# script stops and says so. Tests never compensate for a broken migration.
#
# APPLICATION ROLE IS FIXED at fretvision_app (ratified, Phase 1).
# FRETVISION_APP_ROLE is honoured ONLY to reject a mismatch, because 006
# is intentionally hard-coded to the approved role.
#
# No credential is printed. No credential appears in argv.
# ============================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${REPO_ROOT}/supabase/tests/database"

readonly APP_ROLE='fretvision_app'   # RATIFIED. Not configurable.

SKIP_RESET="${SKIP_RESET:-0}"

die()  { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
info() { printf '==> %s\n' "$1"; }

# ------------------------------------------------------------
# Correction 7: reject any attempt to redirect the role name.
# ------------------------------------------------------------
if [[ -n "${FRETVISION_APP_ROLE:-}" && "${FRETVISION_APP_ROLE}" != "${APP_ROLE}" ]]; then
  die "FRETVISION_APP_ROLE='${FRETVISION_APP_ROLE}' but 006_app_role_privileges is fixed to the ratified role '${APP_ROLE}'. Unset FRETVISION_APP_ROLE or set it to '${APP_ROLE}'."
fi

command -v supabase >/dev/null 2>&1 || die "supabase CLI not found on PATH"
command -v psql     >/dev/null 2>&1 || die "psql not found on PATH"

[[ -d "${TEST_DIR}" ]] || die "test directory not found: ${TEST_DIR}"

# ------------------------------------------------------------
# Credentials (correction 6).
#
# ADMIN: reset_local.sh consumes ADMIN_DB_PASSWORD and builds an ephemeral
# 0600 PGPASSFILE. This runner does the same for its own probe queries: it
# does NOT rely on PGPASSWORD, and it never places a URI in argv.
# ADMIN_DB_PASSWORD defaults to 'postgres' ONLY because that is the local
# Supabase stack's published, non-secret default. Against any non-local
# host, export ADMIN_DB_PASSWORD or PGPASSFILE explicitly.
#
# APPLICATION: FRETVISION_APP_PASSWORD is REQUIRED before a noninteractive
# run, because reset_local.sh will otherwise prompt and a CI run has no TTY.
# ------------------------------------------------------------
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-54322}"
export PGDATABASE="${PGDATABASE:-postgres}"
export PGUSER="${PGUSER:-postgres}"

IS_LOCAL_STACK=0
if [[ "${PGHOST}" == "127.0.0.1" || "${PGHOST}" == "localhost" ]]; then
  IS_LOCAL_STACK=1
fi

if [[ -z "${PGPASSFILE:-}" && -z "${ADMIN_DB_PASSWORD:-}" ]]; then
  if (( IS_LOCAL_STACK )); then
    # Published local-stack default. Not a secret.
    export ADMIN_DB_PASSWORD='postgres'
    info "admin password: using the local Supabase stack default (PGHOST=${PGHOST})"
  else
    die "PGHOST=${PGHOST} is not the local stack. Export ADMIN_DB_PASSWORD or PGPASSFILE explicitly; this runner will not guess a non-local admin credential."
  fi
fi

if [[ "${SKIP_RESET}" != "1" && -z "${FRETVISION_APP_PASSWORD:-}" && ! -t 0 ]]; then
  die "FRETVISION_APP_PASSWORD is unset, stdin is not a TTY, and SKIP_RESET is not set. reset_local.sh cannot prompt. Export FRETVISION_APP_PASSWORD (>= 24 chars) as a masked CI secret."
fi

# ------------------------------------------------------------
# Ephemeral PGPASSFILE for THIS runner's probe queries, mirroring
# reset_local.sh's handling. Removed on exit even on failure.
# ------------------------------------------------------------
TMP_PGPASS=""
cleanup() {
  if [[ -n "${TMP_PGPASS}" && -f "${TMP_PGPASS}" ]]; then
    rm -f -- "${TMP_PGPASS}"
  fi
}
trap cleanup EXIT INT TERM

if [[ -z "${PGPASSFILE:-}" ]]; then
  TMP_PGPASS="$(mktemp)"
  chmod 600 -- "${TMP_PGPASS}"
  printf '%s:%s:%s:%s:%s\n' \
    "${PGHOST}" "${PGPORT}" "*" "${PGUSER}" \
    "$(printf '%s' "${ADMIN_DB_PASSWORD}" | sed 's/\\/\\\\/g; s/:/\\:/g')" \
    > "${TMP_PGPASS}"
  export PGPASSFILE="${TMP_PGPASS}"
fi

# Silent single-value query. No credential in argv.
q() {
  psql --no-psqlrc --quiet --tuples-only --no-align \
       --set=ON_ERROR_STOP=1 --command="$1"
}

# ============================================================
# PREFLIGHT
# ============================================================
info "preflight 1/8: supabase start"
supabase start >/dev/null || die "supabase start failed"

if [[ "${SKIP_RESET}" == "1" ]]; then
  info "preflight 2/8: SKIP_RESET=1 — reset_local.sh is assumed to have ALREADY run"
  printf '    Migrations, bootstrap, and grants are assumed current.\n'
  printf '    The phase-2 gate below will fail loudly if %s is absent.\n' "${APP_ROLE}"
else
  info "preflight 2/8: scripts/reset_local.sh (reset + bootstrap + grants)"
  "${SCRIPT_DIR}/reset_local.sh" \
    || die "reset_local.sh failed — migrations 0001-0007, bootstrap, or grants did not apply"
fi

info "preflight 3/8: supabase status"
supabase status >/dev/null 2>&1 \
  || die "supabase status reports the local stack is not healthy"

info "preflight 4/8: admin connection accepts a query"
[[ "$(q 'select 1')" == "1" ]] \
  || die "admin query failed against ${PGHOST}:${PGPORT}"

info "preflight 5/8: authenticated has USAGE on schema public"
[[ "$(q "select has_schema_privilege('authenticated','public','USAGE')")" == "t" ]] \
  || die "authenticated LACKS USAGE on schema public — MIGRATION 0006 REQUIRES REVISION"

info "preflight 6/8: anon has no USAGE on schema public"
[[ "$(q "select has_schema_privilege('anon','public','USAGE')")" == "f" ]] \
  || die "anon HAS USAGE on schema public — migration 0006's revocation did not take effect"

info "preflight 7/8: authenticated JWT-claim session reads the seeded catalog"
CATALOG_ROWS="$(q "
  begin;
  set local role authenticated;
  set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
  set local request.jwt.claims =
    '{\"sub\":\"00000000-0000-4000-8000-000000000001\",\"role\":\"authenticated\"}';
  select count(*) from public.exercise_revisions where published;
  rollback;
" | tail -n 1)"
[[ -n "${CATALOG_ROWS}" && "${CATALOG_ROWS}" -ge 1 ]] \
  || die "authenticated cannot read the seeded published catalog — the Data API surface produced by MIGRATION 0006 IS BROKEN AND REQUIRES REVISION"

info "preflight 8/8: authenticated JWT-claim session queries the security-invoker views"
q "
  begin;
  set local role authenticated;
  set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
  set local request.jwt.claims =
    '{\"sub\":\"00000000-0000-4000-8000-000000000001\",\"role\":\"authenticated\"}';
  select count(*) from public.v_latest_published_revision;
  select count(*) from public.v_user_practice_summary;
  rollback;
" >/dev/null \
  || die "authenticated cannot query the security_invoker views — MIGRATION 0006 REQUIRES REVISION"

printf '\npreflight: PASS. Stack healthy; migration 0006 grant surface behaves as designed.\n\n'

# ============================================================
# PHASE 1 — migrations only. Explicit paths, deterministic order.
# ============================================================
info "PHASE 1: 001-005 (requires migrations 0001-0007 only)"

supabase test db \
  "${TEST_DIR}/001_schema_invariants.test.sql" \
  "${TEST_DIR}/002_catalog_immutability.test.sql" \
  "${TEST_DIR}/003_lifecycle_and_metrics.test.sql" \
  "${TEST_DIR}/004_rls_isolation.test.sql" \
  "${TEST_DIR}/005_client_privileges.test.sql" \
  || die "PHASE 1 pgTAP assertions failed (see the TAP output above)"

printf '\nPHASE 1: PASS.\n\n'

# ============================================================
# GATE — fretvision_app must exist before phase 2 runs.
# ============================================================
info "gate: verifying role ${APP_ROLE} exists"
ROLE_PRESENT="$(q "select exists (select 1 from pg_catalog.pg_roles where rolname = '${APP_ROLE}')")"
[[ "${ROLE_PRESENT}" == "t" ]] \
  || die "role ${APP_ROLE} does not exist. PHASE 2 requires scripts/bootstrap_role.sql and scripts/grant_fretvision_app.sql. Re-run without SKIP_RESET=1, or run those scripts manually."

# ============================================================
# PHASE 2 — requires bootstrap + grants.
# ============================================================
info "PHASE 2: 006 (requires ${APP_ROLE} + least-privilege grants)"

supabase test db \
  "${TEST_DIR}/006_app_role_privileges.test.sql" \
  || die "PHASE 2 pgTAP assertions failed — the ${APP_ROLE} grant surface does not match scripts/grant_fretvision_app.sql"

printf '\nPHASE 2: PASS.\n\n'
printf 'ALL BATCH D TESTS PASSED.\n'
