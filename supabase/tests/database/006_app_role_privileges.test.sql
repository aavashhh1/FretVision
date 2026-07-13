-- ============================================================
-- 006 — Backend application-role privilege surface
-- Phase 2.
--
-- The application role name is RATIFIED as `fretvision_app` for Phase 1.
-- It is hard-coded here on purpose: this file verifies the specific
-- approved role, not an arbitrary configurable one.
--
-- REQUIRES scripts/bootstrap_role.sql AND scripts/grant_fretvision_app.sql
-- to have already run. `supabase db reset` alone does NOT satisfy this.
-- The runner enforces the ordering; this file additionally fails fast if
-- the role is absent, rather than reporting a misleading pass.
--
-- Asserted entirely through catalog introspection, because
-- `supabase test db` connects as the admin role and cannot re-connect as
-- fretvision_app. has_*_privilege() answers the same question a real
-- connection would, and keeps the role's password out of the harness.
--
-- Plan = 27 assertions.
-- ============================================================
begin;

create extension if not exists pgtap with schema extensions;

-- Fail fast, before the plan, if the phase-2 prerequisite is unmet.
do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_roles where rolname = 'fretvision_app'
  ) then
    raise exception
      'PHASE 2 PREREQUISITE UNMET: role fretvision_app does not exist. '
      'Run scripts/bootstrap_role.sql and scripts/grant_fretvision_app.sql '
      'before 006_app_role_privileges.'
      using errcode = 'insufficient_privilege';
  end if;
end $$;

select plan(27);

-- ============================================================
-- Precondition + role attributes                      [6 assertions]
-- ============================================================
select ok(
  exists (select 1 from pg_catalog.pg_roles where rolname = 'fretvision_app'),
  'PRECONDITION: role fretvision_app exists (bootstrap_role.sql has run)'
);

select ok(
  (select r.rolbypassrls from pg_catalog.pg_roles r
    where r.rolname = 'fretvision_app'),
  'fretvision_app: has BYPASSRLS'
);

select ok(
  (select r.rolcanlogin from pg_catalog.pg_roles r
    where r.rolname = 'fretvision_app'),
  'fretvision_app: has LOGIN'
);

select ok(
  (select not r.rolsuper from pg_catalog.pg_roles r
    where r.rolname = 'fretvision_app'),
  'fretvision_app: is NOT superuser'
);

select ok(
  (select not r.rolcreatedb from pg_catalog.pg_roles r
    where r.rolname = 'fretvision_app'),
  'fretvision_app: does NOT have CREATEDB'
);

select ok(
  (select not r.rolcreaterole from pg_catalog.pg_roles r
    where r.rolname = 'fretvision_app'),
  'fretvision_app: does NOT have CREATEROLE'
);

-- ============================================================
-- Schema privileges                                   [2 assertions]
-- ============================================================
select ok(
  has_schema_privilege('fretvision_app', 'public', 'USAGE'),
  'fretvision_app: has USAGE on schema public'
);

select ok(
  not has_schema_privilege('fretvision_app', 'public', 'CREATE'),
  'fretvision_app: does NOT have CREATE on schema public'
);

-- ============================================================
-- Catalog: SELECT only                                [7 assertions]
-- ============================================================
select ok(has_table_privilege('fretvision_app', 'public.instruments', 'SELECT'),
  'catalog: SELECT on instruments');
select ok(has_table_privilege('fretvision_app', 'public.lessons', 'SELECT'),
  'catalog: SELECT on lessons');
select ok(has_table_privilege('fretvision_app', 'public.exercises', 'SELECT'),
  'catalog: SELECT on exercises');
select ok(has_table_privilege('fretvision_app', 'public.exercise_revisions', 'SELECT'),
  'catalog: SELECT on exercise_revisions');
select ok(has_table_privilege('fretvision_app', 'public.target_position_revisions', 'SELECT'),
  'catalog: SELECT on target_position_revisions');
select ok(has_table_privilege('fretvision_app', 'public.target_string_actions', 'SELECT'),
  'catalog: SELECT on target_string_actions');

select is(
  (select count(*)::int
     from (values
       ('public.instruments'), ('public.lessons'), ('public.exercises'),
       ('public.exercise_revisions'), ('public.target_position_revisions'),
       ('public.target_string_actions')
     ) as t(rel)
    where has_table_privilege('fretvision_app', t.rel, 'INSERT')
       or has_table_privilege('fretvision_app', t.rel, 'UPDATE')
       or has_table_privilege('fretvision_app', t.rel, 'DELETE')),
  0,
  'catalog: fretvision_app holds NO INSERT/UPDATE/DELETE on any catalog table'
);

-- ============================================================
-- Backend-mediated tables: full DML                   [4 assertions]
-- ============================================================
select is(
  (select count(*)::int
     from (values
       ('public.profiles'), ('public.sessions'), ('public.session_samples'),
       ('public.session_metrics'), ('public.session_invalid_reason_counts'),
       ('public.idempotency_records')
     ) as t(rel)
    where not (has_table_privilege('fretvision_app', t.rel, 'SELECT')
           and has_table_privilege('fretvision_app', t.rel, 'INSERT')
           and has_table_privilege('fretvision_app', t.rel, 'UPDATE')
           and has_table_privilege('fretvision_app', t.rel, 'DELETE'))),
  0,
  'DML: SELECT+INSERT+UPDATE+DELETE held on all six backend-mediated tables'
);

select ok(
  has_table_privilege('fretvision_app', 'public.idempotency_records', 'INSERT'),
  'DML: INSERT on idempotency_records'
);

select ok(
  has_table_privilege('fretvision_app', 'public.session_metrics', 'UPDATE'),
  'DML: UPDATE on session_metrics'
);

select is(
  (select count(*)::int
     from pg_catalog.pg_class c
     join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and has_table_privilege('fretvision_app', c.oid, 'TRUNCATE')),
  0,
  'DML: fretvision_app holds no TRUNCATE on any table'
);

-- ============================================================
-- Views                                               [2 assertions]
-- ============================================================
select ok(
  has_table_privilege('fretvision_app', 'public.v_latest_published_revision', 'SELECT'),
  'views: SELECT on v_latest_published_revision'
);

select ok(
  has_table_privilege('fretvision_app', 'public.v_user_practice_summary', 'SELECT'),
  'views: SELECT on v_user_practice_summary'
);

-- ============================================================
-- Functions: exactly the three approved helpers       [6 assertions]
-- ============================================================
select ok(
  has_function_privilege('fretvision_app',
    'public.assert_reason_counts_sum(uuid)', 'EXECUTE'),
  'functions: EXECUTE on assert_reason_counts_sum(uuid)'
);

select ok(
  has_function_privilege('fretvision_app',
    'public.er_is_published(uuid)', 'EXECUTE'),
  'functions: EXECUTE on er_is_published(uuid)'
);

select ok(
  has_function_privilege('fretvision_app',
    'public.tsa_parent_published(uuid)', 'EXECUTE'),
  'functions: EXECUTE on tsa_parent_published(uuid)'
);

select is(
  (select count(*)::int
     from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prorettype = 'pg_catalog.trigger'::pg_catalog.regtype
      and has_function_privilege('fretvision_app', p.oid, 'EXECUTE')),
  0,
  'functions: no EXECUTE on any trigger function in public'
);

select is(
  (select count(*)::int
     from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('fretvision_app', p.oid, 'EXECUTE')),
  3,
  'functions: EXECUTE held on exactly three functions in public'
);

select is(
  (select array_agg(p.proname order by p.proname)::text[]
     from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('fretvision_app', p.oid, 'EXECUTE')),
  array['assert_reason_counts_sum', 'er_is_published', 'tsa_parent_published']::text[],
  'functions: the three EXECUTE grants are exactly the approved helpers'
);

select finish();

rollback;
