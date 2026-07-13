-- ============================================================
-- scripts/grant_fretvision_app.sql
-- Explicit least-privilege grants for the backend application role.
--
-- NOT a migration. Runs after `supabase db reset` and after
-- scripts/bootstrap_role.sql, because migrations must apply on a
-- database where this role does not exist.
--
-- No password, no CREATE ROLE, no GRANT ... ON ALL TABLES,
-- no GRANT ... ON ALL FUNCTIONS.
--
-- CONTRACT — fragment. The caller must have issued:
--     SET fretvision.app_role = '<role>';
-- before including this file. No secret is consumed here, so no
-- transaction or logging suppression is required.
--
-- Privilege model:
--   * Catalog -> SELECT only. Authoring is migration/admin-only.
--   * profiles / sessions / session_samples / session_metrics /
--     session_invalid_reason_counts / idempotency_records
--             -> SELECT, INSERT, UPDATE, DELETE — the DML the four
--                FastAPI commands actually need.
--   * Views   -> SELECT. security_invoker + BYPASSRLS means the backend
--                sees all rows; it filters by JWT `sub` in app code.
--   * Functions -> EXECUTE on the three non-trigger helper functions
--                only. Trigger functions (trg_*) return `trigger` and are
--                invoked by the trigger machinery under the definer's
--                privileges, so they need no grant. Migration 0006 has
--                already revoked the implicit PUBLIC EXECUTE from every
--                function in `public`, which is why these three must be
--                granted back explicitly to the app role.
--   * No sequence grants: every surrogate key in 0001–0003 is a uuid
--     default or a client-supplied uuid. No table owns a sequence.
-- ============================================================

do $grants$
declare
  v_role text := current_setting('fretvision.app_role', true);
begin
  if v_role is null or pg_catalog.length(v_role) = 0 then
    raise exception 'fretvision.app_role not set; run this file through the reset wrapper';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_roles r where r.rolname = v_role
  ) then
    raise exception 'role % does not exist; run scripts/bootstrap_role.sql first', v_role;
  end if;

  execute pg_catalog.format('grant usage on schema public to %I', v_role);

  -- ---------- Catalog: read-only ----------
  execute pg_catalog.format(
    'grant select on public.instruments to %I', v_role);
  execute pg_catalog.format(
    'grant select on public.lessons to %I', v_role);
  execute pg_catalog.format(
    'grant select on public.exercises to %I', v_role);
  execute pg_catalog.format(
    'grant select on public.exercise_revisions to %I', v_role);
  execute pg_catalog.format(
    'grant select on public.target_position_revisions to %I', v_role);
  execute pg_catalog.format(
    'grant select on public.target_string_actions to %I', v_role);

  -- ---------- User-owned / backend-mediated: DML ----------
  execute pg_catalog.format(
    'grant select, insert, update, delete on public.profiles to %I', v_role);
  execute pg_catalog.format(
    'grant select, insert, update, delete on public.sessions to %I', v_role);
  execute pg_catalog.format(
    'grant select, insert, update, delete on public.session_samples to %I', v_role);
  execute pg_catalog.format(
    'grant select, insert, update, delete on public.session_metrics to %I', v_role);
  execute pg_catalog.format(
    'grant select, insert, update, delete on public.session_invalid_reason_counts to %I', v_role);
  execute pg_catalog.format(
    'grant select, insert, update, delete on public.idempotency_records to %I', v_role);

  -- ---------- Views: read-only ----------
  execute pg_catalog.format(
    'grant select on public.v_latest_published_revision to %I', v_role);
  execute pg_catalog.format(
    'grant select on public.v_user_practice_summary to %I', v_role);

  -- ---------- Helper functions: EXECUTE, app role only ----------
  execute pg_catalog.format(
    'grant execute on function public.assert_reason_counts_sum(uuid) to %I', v_role);
  execute pg_catalog.format(
    'grant execute on function public.er_is_published(uuid) to %I', v_role);
  execute pg_catalog.format(
    'grant execute on function public.tsa_parent_published(uuid) to %I', v_role);
end
$grants$;
