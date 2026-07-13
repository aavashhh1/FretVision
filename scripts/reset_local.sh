#!/usr/bin/env bash
# ============================================================
# scripts/reset_local.sh
# Full local reset for the FretVision database.
#
# Uses an accessible PostgreSQL superuser for role bootstrap.
# With the local Supabase Docker stack, supabase_admin is normally
# the internal superuser while postgres is deliberately restricted.
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_PATH="${REPO_ROOT}/supabase/config.toml"

APP_ROLE="fretvision_app"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

if [[ -n "${FRETVISION_APP_ROLE:-}" && "${FRETVISION_APP_ROLE}" != "${APP_ROLE}" ]]; then
  die "FRETVISION_APP_ROLE must be '${APP_ROLE}'"
fi

if [[ -x "${REPO_ROOT}/node_modules/.bin/supabase" ]]; then
  SUPABASE_CLI="${REPO_ROOT}/node_modules/.bin/supabase"
elif command -v supabase >/dev/null 2>&1; then
  SUPABASE_CLI="$(command -v supabase)"
else
  die "Supabase CLI not found. Run: npm install supabase --save-dev"
fi

if command -v psql >/dev/null 2>&1; then
  PSQL_MODE="host"
  PSQL_BIN="$(command -v psql)"
else
  command -v docker >/dev/null 2>&1 || die "neither psql nor docker is available"
  PSQL_MODE="docker"
  PSQL_BIN=""
fi

resolve_db_container() {
  if [[ -n "${SUPABASE_DB_CONTAINER:-}" ]]; then
    printf '%s' "${SUPABASE_DB_CONTAINER}"
    return
  fi

  if [[ -f "${CONFIG_PATH}" ]]; then
    local project_id
    project_id="$(
      sed -nE 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
        "${CONFIG_PATH}" |
        head -n 1
    )"

    if [[ -n "${project_id}" ]]; then
      printf 'supabase_db_%s' "${project_id}"
      return
    fi
  fi

  printf 'supabase_db_FretVision'
}

DB_CONTAINER="$(resolve_db_container)"
DOCKER_ADMIN_ROLE=""

assert_container_running() {
  local state
  state="$(docker inspect --format '{{.State.Running}}' "${DB_CONTAINER}" 2>/dev/null || true)"

  [[ "${state}" == "true" ]] ||
    die "Supabase database container '${DB_CONTAINER}' is not running"
}

resolve_docker_superuser() {
  assert_container_running

  local candidates=()
  local candidate
  local result

  if [[ -n "${SUPABASE_DB_SUPERUSER:-}" ]]; then
    candidates+=("${SUPABASE_DB_SUPERUSER}")
  fi

  candidates+=("supabase_admin" "postgres")

  for candidate in "${candidates[@]}"; do
    result="$(
      docker exec -i "${DB_CONTAINER}" \
        psql \
        -U "${candidate}" \
        -d postgres \
        --no-psqlrc \
        --quiet \
        --tuples-only \
        --no-align \
        --set=ON_ERROR_STOP=1 \
        --command="select rolsuper from pg_catalog.pg_roles where rolname = current_user" \
        2>/dev/null |
        tail -n 1 |
        tr -d '[:space:]' || true
    )"

    if [[ "${result}" == "t" ]]; then
      printf '%s' "${candidate}"
      return
    fi
  done

  die "no accessible PostgreSQL superuser found in '${DB_CONTAINER}'"
}

run_psql() {
  if [[ "${PSQL_MODE}" == "docker" ]]; then
    docker exec -i "${DB_CONTAINER}" \
      psql -U "${DOCKER_ADMIN_ROLE}" -d postgres "$@"
  else
    "${PSQL_BIN}" "$@"
  fi
}

for required_file in \
  "${SCRIPT_DIR}/bootstrap_role.sql" \
  "${SCRIPT_DIR}/grant_fretvision_app.sql"
do
  [[ -f "${required_file}" ]] || die "required file not found: ${required_file}"
done

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-54322}"
export PGDATABASE="${PGDATABASE:-postgres}"
export PGUSER="${PGUSER:-postgres}"

IS_LOCAL_STACK="false"
if [[ "${PGHOST}" == "127.0.0.1" || "${PGHOST}" == "localhost" ]]; then
  IS_LOCAL_STACK="true"
fi

if [[ "${PSQL_MODE}" == "docker" && "${IS_LOCAL_STACK}" != "true" ]]; then
  die "Docker psql fallback is local-only"
fi

TMP_PGPASS=""
ORIGINAL_DIR="$(pwd)"

cleanup() {
  unset FRETVISION_APP_PASSWORD || true

  if [[ -n "${TMP_PGPASS}" && -f "${TMP_PGPASS}" ]]; then
    rm -f -- "${TMP_PGPASS}"
  fi

  cd -- "${ORIGINAL_DIR}" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

cd -- "${REPO_ROOT}"

printf '==> supabase start\n'
"${SUPABASE_CLI}" start

printf '==> supabase db reset\n'
"${SUPABASE_CLI}" db reset

if [[ "${PSQL_MODE}" == "docker" ]]; then
  DOCKER_ADMIN_ROLE="$(resolve_docker_superuser)"
  printf "==> admin psql: using Docker container '%s' as '%s'\n" \
    "${DB_CONTAINER}" "${DOCKER_ADMIN_ROLE}"
else
  if [[ -z "${PGPASSFILE:-}" ]]; then
    if [[ -z "${ADMIN_DB_PASSWORD:-}" ]]; then
      if [[ "${IS_LOCAL_STACK}" == "true" ]]; then
        ADMIN_DB_PASSWORD="postgres"
      else
        if [[ ! -t 0 ]]; then
          die "neither PGPASSFILE nor ADMIN_DB_PASSWORD is set, and stdin is not a TTY"
        fi

        printf 'Admin DB password for %s@%s:%s (input hidden): ' \
          "${PGUSER}" "${PGHOST}" "${PGPORT}" >&2

        IFS= read -r -s ADMIN_DB_PASSWORD
        printf '\n' >&2
      fi
    fi

    [[ -n "${ADMIN_DB_PASSWORD}" ]] || die "empty admin password"

    TMP_PGPASS="$(mktemp)"
    chmod 600 -- "${TMP_PGPASS}"

    printf '%s:%s:%s:%s:%s\n' \
      "${PGHOST}" \
      "${PGPORT}" \
      "*" \
      "${PGUSER}" \
      "$(printf '%s' "${ADMIN_DB_PASSWORD}" | sed 's/\\/\\\\/g; s/:/\\:/g')" \
      > "${TMP_PGPASS}"

    export PGPASSFILE="${TMP_PGPASS}"
    unset ADMIN_DB_PASSWORD
  fi

  IS_SUPERUSER="$(
    "${PSQL_BIN}" \
      --no-psqlrc \
      --quiet \
      --tuples-only \
      --no-align \
      --set=ON_ERROR_STOP=1 \
      --command="select rolsuper from pg_catalog.pg_roles where rolname = current_user" |
      tail -n 1 |
      tr -d '[:space:]'
  )"

  [[ "${IS_SUPERUSER}" == "t" ]] ||
    die "PGUSER '${PGUSER}' is not a PostgreSQL superuser"
fi

if [[ -z "${FRETVISION_APP_PASSWORD:-}" ]]; then
  if [[ ! -t 0 ]]; then
    die "FRETVISION_APP_PASSWORD is unset and stdin is not a TTY"
  fi

  printf 'Password for role %s (input hidden): ' "${APP_ROLE}" >&2
  IFS= read -r -s FRETVISION_APP_PASSWORD
  printf '\n' >&2
fi

[[ -n "${FRETVISION_APP_PASSWORD}" ]] ||
  die "empty application-role password"

(( ${#FRETVISION_APP_PASSWORD} >= 24 )) ||
  die "application-role password must be at least 24 characters"

sql_literal() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

printf '==> creating/updating role %s\n' "${APP_ROLE}"

{
  printf 'begin;\n'
  printf "set local log_statement = 'none';\n"
  printf "set local log_min_error_statement = 'panic';\n"
  printf 'set local log_min_duration_statement = -1;\n'
  printf 'set local log_min_duration_sample = -1;\n'
  printf 'set local log_transaction_sample_rate = 0;\n'
  printf 'set local fretvision.app_role = %s;\n' "$(sql_literal "${APP_ROLE}")"
  printf 'set local fretvision.app_pw = %s;\n' "$(sql_literal "${FRETVISION_APP_PASSWORD}")"
  cat -- "${SCRIPT_DIR}/bootstrap_role.sql"
  printf '\ncommit;\n'
} | run_psql \
      --no-psqlrc \
      --quiet \
      --set=ON_ERROR_STOP=1 \
      --file=- >/dev/null

unset FRETVISION_APP_PASSWORD

printf '==> applying least-privilege grants to %s\n' "${APP_ROLE}"

{
  printf 'set fretvision.app_role = %s;\n' "$(sql_literal "${APP_ROLE}")"
  cat -- "${SCRIPT_DIR}/grant_fretvision_app.sql"
} | run_psql \
      --no-psqlrc \
      --quiet \
      --set=ON_ERROR_STOP=1 \
      --file=-

printf '==> reset complete. Role %s exists with least-privilege grants.\n' "${APP_ROLE}"
printf '    The caller may now run the pgTAP database test phases.\n'