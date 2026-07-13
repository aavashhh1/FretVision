# FretVision — Local Database Scripts

These scripts sit **outside** the migration chain on purpose. Migrations
`0001`–`0007` must apply to a database where the backend application role does
not exist, so nothing under `supabase/migrations/` may name that role, create
it, or grant to it.

## Execution order

| Step | Command | Credential |
|---|---|---|
| 1 | `supabase start` | — |
| 2 | `supabase db reset` — applies `0001`–`0007` | Supabase CLI |
| 3 | `scripts/bootstrap_role.sql` — create/update `fretvision_app` | admin |
| 4 | `scripts/grant_fretvision_app.sql` — explicit least-privilege grants | admin |
| 5 | SQL / RLS / grant test harness | **Batch D — not yet present** |

Steps 1–4 are wrapped by:

```bash
./scripts/reset_local.sh          # macOS / Linux / WSL
```

```powershell
.\scripts\reset_local.ps1         # Windows PowerShell 5.1+ / pwsh 7+
```

Both wrappers abort on the first failing command (`set -Eeuo pipefail` /
`$ErrorActionPreference = 'Stop'`). The PowerShell wrapper places pgpass
creation, bootstrap, and grants inside one outer `try`/`finally`, so the
ephemeral pgpass file is removed even when bootstrap fails partway.

## Admin capability requirement

The admin credential used for steps 3 and 4 must be **superuser-equivalent**, or
otherwise hold every capability below:

- Assigning `BYPASSRLS` to another role (`CREATE ROLE ... BYPASSRLS`).
- Changing the `log_*` settings listed under *Logging protection*. Those GUCs are
  `SUSET`-class: a non-superuser cannot lower them, and `SET LOCAL` on them will
  fail rather than silently degrade.

On a local Supabase stack the default `postgres` superuser satisfies this. On a
hosted Supabase project, use the credential the platform designates for
role management; a project's `service_role` API key is **not** a Postgres
credential and cannot be used here.

## The two SQL files are fragments, not standalone scripts

Neither `bootstrap_role.sql` nor `grant_fretvision_app.sql` can be run with a
bare `psql -f`. Both read their inputs from session GUCs that the wrapper sets.

`bootstrap_role.sql` additionally depends on statement ordering that only the
wrapper can provide. The wrapper sends, in this exact order:
BEGIN;
SET LOCAL log_statement = 'none';
SET LOCAL log_min_error_statement = 'panic';
SET LOCAL log_min_duration_statement = -1;
SET LOCAL log_min_duration_sample = -1;
SET LOCAL log_transaction_sample_rate = 0;
SET LOCAL fretvision.app_role = '<role>';
SET LOCAL fretvision.app_pw   = '<password>';
-- contents of bootstrap_role.sql
COMMIT;

**Statement order is the enforcement mechanism.** There is no in-SQL guard that
can verify it. `SET LOCAL` outside a transaction block is a silent no-op
(warning only), and `current_setting('transaction_isolation')` returns a value
inside PostgreSQL's implicit per-statement transaction as well, so it cannot
distinguish an explicit `BEGIN` from no `BEGIN` at all. `BEGIN` must come first,
and every logging suppression must be in force **before** the password-bearing
GUC is transmitted.

## Logging protection — scope and limits

The five `SET LOCAL` statements above cover PostgreSQL's **standard** logging
paths for the duration of the bootstrap transaction:

| Setting | What it suppresses |
|---|---|
| `log_statement = 'none'` | Statement-text logging for DDL/DML, including `CREATE`/`ALTER ROLE ... PASSWORD`. |
| `log_min_error_statement = 'panic'` | The statement text that would otherwise accompany an **error** — so a *failing* `CREATE ROLE` does not write its own password-bearing text to the error log. |
| `log_min_duration_statement = -1` | Slow-statement logging. |
| `log_min_duration_sample = -1` | Sampled slow-statement logging. |
| `log_transaction_sample_rate = 0` | Per-transaction statement sampling. |

**This is not a guarantee of universal secrecy.** It does not cover, and cannot
cover:

- Third-party audit extensions such as `pgaudit`, which log through their own
  hooks and are not governed by these GUCs.
- `pg_stat_statements`, which normalizes literals but should still be treated as
  out of scope for a secret-bearing statement.
- Log collection at a layer below PostgreSQL — a network capture, a
  connection-level proxy, or a hosted platform that mirrors traffic.
- WAL, which records the resulting `pg_authid` row (the password is stored
  hashed by `password_encryption`, not in plaintext, but the write itself
  happens).

Treat the protection as: *the password does not appear in PostgreSQL's own log
files under a standard configuration.* If your deployment runs `pgaudit` or an
equivalent, verify its behaviour separately before running these scripts against
anything other than a local stack.

## Environment

| Variable | Required | Purpose |
|---|---|---|
| `FRETVISION_APP_PASSWORD` | no (prompted if unset) | Password for the backend role. Minimum 24 characters. |
| `FRETVISION_APP_ROLE` | no | Role name. Defaults to `fretvision_app`. |
| `PGHOST` / `PGPORT` / `PGDATABASE` / `PGUSER` | no | Admin connection. Default to the local Supabase stack (`127.0.0.1:54322/postgres` as `postgres`). |
| `PGPASSFILE` | no | Path to an existing pgpass file for the admin credential. If unset, the wrapper builds an ephemeral one and deletes it on exit. |
| `ADMIN_DB_PASSWORD` | no (prompted if unset and `PGPASSFILE` is unset) | Admin password, used only to populate the ephemeral pgpass file. |

Do not commit any of these. `.env` files carrying them must be git-ignored, and
CI must supply them as masked secrets with secret scanning enabled.

## Security assumptions

- **No password literal exists in any tracked file.**
- **No credential is passed as a command-line argument.** The admin connection
  uses `PGHOST` / `PGPORT` / `PGDATABASE` / `PGUSER` plus `PGPASSFILE` — never a
  `postgresql://user:pass@host/db` URI. A URI on the command line would place the
  admin password in `argv`, which is world-readable through
  `/proc/<pid>/cmdline` on Linux and enumerable via `ps` and WMI. libpq reads
  `PGPASSFILE` from the filesystem instead.
- **The ephemeral pgpass file is short-lived and access-restricted.** The Bash
  wrapper creates it with `mktemp` + `chmod 600` and removes it via an `EXIT`
  trap. The PowerShell wrapper writes it to `%TEMP%`, strips inherited ACLs,
  grants `FullControl` to the current user only, and deletes it in the outer
  `finally` block — which runs even if bootstrap or grants throw. If `PGPASSFILE`
  is already exported, the wrapper honours it and neither creates nor deletes
  anything. Where the OS supports it, prefer a persistent `~/.pgpass` (mode
  `0600`) and export `PGPASSFILE` yourself.
- **The application-role password is kept out of PostgreSQL's standard logs.** It
  is sent as a `SET LOCAL` GUC over `psql` **stdin**, inside a transaction where
  all five logging settings above are already in effect. It is never an `argv`
  element and never written to disk. See *Logging protection — scope and limits*
  for what this does and does not cover.
- **No password is echoed.** Interactive prompts read silently (`read -s`,
  `Read-Host -AsSecureString`). Neither wrapper prints any password or a
  derivative of one.
- **The admin credential and the backend credential are distinct.** The admin
  credential is superuser-equivalent and used only by these scripts. The
  backend's `DATABASE_URL` carries `fretvision_app` — `LOGIN`, `BYPASSRLS`,
  `NOSUPERUSER`, `NOCREATEDB`, `NOCREATEROLE` — and lives only in the application
  secret store.
- **`BYPASSRLS` is deliberate.** The backend enforces ownership from the JWT
  `sub` in application code, never from a request body. RLS remains the control
  for direct browser reads through the Supabase Data API.
- **Grants are explicit.** `grant_fretvision_app.sql` never uses
  `GRANT ... ON ALL TABLES IN SCHEMA` or `GRANT ... ON ALL FUNCTIONS IN SCHEMA`.
  Catalog tables are `SELECT`-only for the backend; authoring is
  migration/admin-only. Only `profiles`, `sessions`, `session_samples`,
  `session_metrics`, `session_invalid_reason_counts`, and `idempotency_records`
  receive DML. `EXECUTE` is granted on exactly three helper functions —
  `assert_reason_counts_sum(uuid)`, `er_is_published(uuid)`,
  `tsa_parent_published(uuid)` — and on nothing else; the `trg_*` trigger
  functions are invoked by the trigger machinery and need no grant.
- **Clients never write, and never execute.** Migration `0006` grants
  `authenticated` `SELECT` only, on the approved tables and the two
  `security_invoker` views. `anon` and `PUBLIC` receive nothing — no `USAGE` on
  `public`, no table privileges, no function `EXECUTE`. Note that PostgreSQL's
  implicit `EXECUTE`-to-`PUBLIC` on new functions is a **global** default, so
  `0006` cancels it with an unqualified
  `ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`; an
  `IN SCHEMA` form would record a schema-scoped entry that does not remove the
  global default. `idempotency_records` has RLS enabled with zero policies and no
  client grant.

## Password rotation

Do not run `reset_local.sh` or `reset_local.ps1` solely to rotate the backend
role password because those scripts execute `supabase db reset`.

For password rotation, run only the bootstrap transaction against the existing
database:

- Connect using the superuser-equivalent admin credential through the approved
   `PG*` variables and `PGPASSFILE`.
- Begin a transaction.
- Apply all standard PostgreSQL logging-suppression settings documented above.
- Set `fretvision.app_role` and the new `fretvision.app_pw` as transaction-local
   GUCs.
- Include `scripts/bootstrap_role.sql`.
- Commit.
- Update the backend secret store's `DATABASE_URL` in the same change window.

The bootstrap block detects the existing role and executes `ALTER ROLE ...
PASSWORD`. Existing grants do not need to be reapplied.