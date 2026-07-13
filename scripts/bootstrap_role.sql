-- ============================================================
-- scripts/bootstrap_role.sql
-- Creates or updates the backend application role.
--
-- NOT a migration. Never run by `supabase db reset`. Lives outside the
-- migration chain because it names a role and consumes a secret.
--
-- CONTRACT — this file is a FRAGMENT, not a standalone script.
-- The caller must have already opened an explicit transaction and, in
-- this exact order, issued:
--
--     BEGIN;
--     SET LOCAL log_statement = 'none';
--     SET LOCAL log_min_error_statement = 'panic';
--     SET LOCAL log_min_duration_statement = -1;
--     SET LOCAL log_min_duration_sample = -1;
--     SET LOCAL log_transaction_sample_rate = 0;
--     SET LOCAL fretvision.app_role = '<role>';
--     SET LOCAL fretvision.app_pw   = '<password>';
--     \i scripts/bootstrap_role.sql
--     COMMIT;
--
-- Statement ORDER is the enforcement mechanism. There is no in-SQL guard
-- that can verify it: SET LOCAL outside a transaction block is a silent
-- no-op (WARNING only), and current_setting('transaction_isolation')
-- returns a value inside PostgreSQL's implicit per-statement transaction
-- too, so it cannot distinguish an explicit BEGIN from no BEGIN at all.
-- The wrapper owns this ordering. Do not run this file with a bare
-- `psql -f`.
--
-- Why the ordering matters: every logging channel that could echo the
-- password-bearing SET LOCAL — or the CREATE/ALTER ROLE ... PASSWORD
-- statement itself — must be suppressed BEFORE the secret is transmitted.
-- Lowering log_min_error_statement to 'panic' also prevents a failing
-- CREATE ROLE from writing its own statement text into the error log.
--
-- Security assumptions:
--   * The admin connection is superuser-equivalent: assigning BYPASSRLS
--     and lowering the log_* settings both require it.
--   * The admin connection is supplied via PGHOST/PGPORT/PGDATABASE/
--     PGUSER + PGPASSFILE, never as a URI on the command line.
--   * The application password comes from a secret store or a silent
--     prompt, is never echoed, never committed, never logged.
--   * BYPASSRLS is granted here, not in migrations: the backend enforces
--     ownership from the JWT `sub` in application code.
-- ============================================================

do $bootstrap$
declare
  v_role  text := current_setting('fretvision.app_role', true);
  v_pw    text := current_setting('fretvision.app_pw', true);
  v_state text;
begin
  if v_role is null or pg_catalog.length(v_role) = 0 then
    raise exception 'fretvision.app_role not set; run this file through the reset wrapper';
  end if;

  if v_pw is null or pg_catalog.length(v_pw) < 24 then
    raise exception 'fretvision.app_pw not set, or shorter than 24 characters';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_roles r
    where r.rolname = v_role
  ) then
    begin
      execute pg_catalog.format(
        'create role %I with login bypassrls password %L',
        v_role,
        v_pw
      );
    exception
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        raise exception using
          errcode = v_state,
          message = pg_catalog.format(
            'failed to create backend application role %I',
            v_role
          );
    end;
  else
    begin
      execute pg_catalog.format(
        'alter role %I with login bypassrls password %L',
        v_role,
        v_pw
      );
    exception
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        raise exception using
          errcode = v_state,
          message = pg_catalog.format(
            'failed to update backend application role %I',
            v_role
          );
    end;
  end if;

  execute pg_catalog.format(
    'alter role %I with nosuperuser nocreatedb nocreaterole',
    v_role
  );
end
$bootstrap$;

-- No NOTICE is emitted describing the role state. Nothing derived from
-- the password is written to stdout, stderr, or the server log.