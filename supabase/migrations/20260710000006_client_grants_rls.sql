-- ============================================================
-- 0006 — Client-facing grants + RLS
-- Client roles only (anon, authenticated) and PUBLIC. The backend
-- application role is provisioned and granted OUTSIDE version control
-- (scripts/bootstrap_role.sql, scripts/grant_fretvision_app.sql) and is
-- deliberately never named here, so `supabase db reset` applies cleanly
-- on a database where that role does not exist.
--
-- Model: grants gate privilege, RLS gates rows.
--   * PUBLIC         -> no schema usage, no function EXECUTE.
--   * anon           -> no schema usage, no application-data access.
--   * authenticated  -> USAGE on schema public; SELECT only. No client
--                       INSERT/UPDATE/DELETE path exists on any table.
--                       All writes are backend-mediated.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Baseline revocation (tables, sequences, functions, schema)
-- ------------------------------------------------------------
revoke all on all tables    in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;

-- Functions already created by 0004 (trigger + helper functions) carry an
-- implicit EXECUTE grant to PUBLIC from creation time. Strip it, along with
-- anything the client roles may hold.
revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all routines  in schema public from public, anon, authenticated;

revoke usage on schema public from public, anon;
grant  usage on schema public to authenticated;

-- ------------------------------------------------------------
-- 2. Default privileges for future objects.
--
-- PostgreSQL's implicit EXECUTE-to-PUBLIC on newly created functions is a
-- GLOBAL default, not a per-schema one. `ALTER DEFAULT PRIVILEGES IN SCHEMA
-- public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` records a schema-scoped
-- entry that does not cancel that global default, so it has no effect. The
-- revocation must be issued without IN SCHEMA.
-- ------------------------------------------------------------
alter default privileges
  revoke execute on functions from public;

-- Table/sequence defaults are not implicitly granted to PUBLIC, but the
-- schema-scoped revocations below still guard against a later migration
-- inheriting a broader default for the client roles.
alter default privileges in schema public
  revoke all on tables from public, anon, authenticated;
alter default privileges in schema public
  revoke all on sequences from public, anon, authenticated;

-- ------------------------------------------------------------
-- 3. Enable + force RLS on every application table
--    FORCE so that even the table owner is subject to policies; the
--    backend role bypasses via BYPASSRLS, not via ownership.
-- ------------------------------------------------------------
alter table public.instruments                   enable row level security;
alter table public.lessons                       enable row level security;
alter table public.exercises                     enable row level security;
alter table public.exercise_revisions            enable row level security;
alter table public.target_position_revisions     enable row level security;
alter table public.target_string_actions         enable row level security;
alter table public.profiles                      enable row level security;
alter table public.sessions                      enable row level security;
alter table public.session_samples               enable row level security;
alter table public.session_metrics               enable row level security;
alter table public.session_invalid_reason_counts enable row level security;
alter table public.idempotency_records           enable row level security;

alter table public.instruments                   force row level security;
alter table public.lessons                       force row level security;
alter table public.exercises                     force row level security;
alter table public.exercise_revisions            force row level security;
alter table public.target_position_revisions     force row level security;
alter table public.target_string_actions         force row level security;
alter table public.profiles                      force row level security;
alter table public.sessions                      force row level security;
alter table public.session_samples               force row level security;
alter table public.session_metrics               force row level security;
alter table public.session_invalid_reason_counts force row level security;
alter table public.idempotency_records           force row level security;

-- ------------------------------------------------------------
-- 4. Catalog SELECT grants (authenticated only)
-- ------------------------------------------------------------
grant select on public.instruments               to authenticated;
grant select on public.lessons                   to authenticated;
grant select on public.exercises                 to authenticated;
grant select on public.exercise_revisions        to authenticated;
grant select on public.target_position_revisions to authenticated;
grant select on public.target_string_actions     to authenticated;

-- ------------------------------------------------------------
-- 5. User-owned SELECT grants (authenticated only)
--    idempotency_records intentionally receives NO grant.
-- ------------------------------------------------------------
grant select on public.profiles                      to authenticated;
grant select on public.sessions                      to authenticated;
grant select on public.session_samples               to authenticated;
grant select on public.session_metrics               to authenticated;
grant select on public.session_invalid_reason_counts to authenticated;

-- ------------------------------------------------------------
-- 6. View SELECT grants (security_invoker => underlying RLS applies)
-- ------------------------------------------------------------
grant select on public.v_latest_published_revision to authenticated;
grant select on public.v_user_practice_summary     to authenticated;

-- No function EXECUTE is granted to anon or authenticated. Trigger
-- functions are invoked by the trigger machinery, not called directly.
-- The backend role receives EXECUTE on the three helper functions via
-- scripts/grant_fretvision_app.sql.

-- ------------------------------------------------------------
-- 7. Catalog policies — published-only, read-only.
--    Reachability is anchored on exercise_revisions.published: an
--    unpublished revision and its whole subtree stay invisible.
-- ------------------------------------------------------------
create policy instruments_select_authenticated
  on public.instruments
  for select
  to authenticated
  using (true);

create policy lessons_select_authenticated
  on public.lessons
  for select
  to authenticated
  using (true);

create policy exercises_select_authenticated
  on public.exercises
  for select
  to authenticated
  using (true);

create policy exercise_revisions_select_published
  on public.exercise_revisions
  for select
  to authenticated
  using (published);

create policy tpr_select_published_parent
  on public.target_position_revisions
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.exercise_revisions er
      where er.id = target_position_revisions.exercise_revision_id
        and er.published
    )
  );

create policy tsa_select_published_grandparent
  on public.target_string_actions
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.target_position_revisions tpr
      join public.exercise_revisions er
        on er.id = tpr.exercise_revision_id
      where tpr.id = target_string_actions.target_position_revision_id
        and er.published
    )
  );

-- ------------------------------------------------------------
-- 8. User-owned policies — owner-only, read-only.
--    Ownership derives from the JWT subject via auth.uid().
--    session_samples / session_metrics / session_invalid_reason_counts
--    carry no user_id column, so ownership is resolved through sessions.
-- ------------------------------------------------------------
create policy profiles_select_own
  on public.profiles
  for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy sessions_select_own
  on public.sessions
  for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy session_samples_select_own
  on public.session_samples
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.sessions s
      where s.id = session_samples.session_id
        and s.user_id = (select auth.uid())
    )
  );

create policy session_metrics_select_own
  on public.session_metrics
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.sessions s
      where s.id = session_metrics.session_id
        and s.user_id = (select auth.uid())
    )
  );

create policy sirc_select_own
  on public.session_invalid_reason_counts
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.session_metrics m
      join public.sessions s on s.id = m.session_id
      where m.session_id = session_invalid_reason_counts.session_id
        and s.user_id = (select auth.uid())
    )
  );

-- ------------------------------------------------------------
-- 9. idempotency_records — no grant, no policy.
--    RLS is enabled with zero permissive policies => default-deny for
--    every non-bypassing role, and the absent SELECT grant denies it a
--    second time. The backend reaches it via BYPASSRLS plus the explicit
--    DML grant applied outside version control.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- 10. Supporting indexes for RLS predicate performance
-- ------------------------------------------------------------
create index if not exists idx_er_published
  on public.exercise_revisions (published, exercise_id, revision_no desc);
create index if not exists idx_tpr_exercise_revision
  on public.target_position_revisions (exercise_revision_id);
create index if not exists idx_tsa_target
  on public.target_string_actions (target_position_revision_id);