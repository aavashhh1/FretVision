-- ============================================================
-- 005 — Client-role privilege surface (authenticated / anon / PUBLIC)
-- Phase 1. Pure catalog introspection: has_*_privilege() is
-- authoritative and does not require assuming the role.
-- Plan = 34 assertions.
-- ============================================================
begin;

create extension if not exists pgtap with schema extensions;

select plan(34);

-- ============================================================
-- Schema USAGE                                        [3 assertions]
-- ============================================================
select ok(
  has_schema_privilege('authenticated', 'public', 'USAGE'),
  'authenticated: has USAGE on schema public'
);

select ok(
  not has_schema_privilege('anon', 'public', 'USAGE'),
  'anon: has no USAGE on schema public'
);

select is(
  (
    select count(*)::int
    from pg_catalog.pg_namespace n
    cross join lateral pg_catalog.aclexplode(
      coalesce(
        n.nspacl,
        pg_catalog.acldefault('n'::"char", n.nspowner)
      )
    ) a
    where n.nspname = 'public'
      and a.grantee = 0
      and a.privilege_type = 'USAGE'
  ),
  0,
  'PUBLIC: has no USAGE ACL entry on schema public'
);

-- ============================================================
-- authenticated: approved SELECT grants               [7 assertions]
-- ============================================================
select ok(has_table_privilege('authenticated', 'public.instruments', 'SELECT'),
  'authenticated: SELECT on instruments');
select ok(has_table_privilege('authenticated', 'public.exercise_revisions', 'SELECT'),
  'authenticated: SELECT on exercise_revisions');
select ok(has_table_privilege('authenticated', 'public.profiles', 'SELECT'),
  'authenticated: SELECT on profiles');
select ok(has_table_privilege('authenticated', 'public.sessions', 'SELECT'),
  'authenticated: SELECT on sessions');
select ok(has_table_privilege('authenticated', 'public.session_metrics', 'SELECT'),
  'authenticated: SELECT on session_metrics');
select ok(has_table_privilege('authenticated', 'public.v_user_practice_summary', 'SELECT'),
  'authenticated: SELECT on v_user_practice_summary');
select ok(has_table_privilege('authenticated', 'public.v_latest_published_revision', 'SELECT'),
  'authenticated: SELECT on v_latest_published_revision');

-- ============================================================
-- authenticated: no write privilege anywhere         [11 assertions]
-- ============================================================
select is(
  (select count(*)::int
     from pg_catalog.pg_class c
     join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'v')
      and (has_table_privilege('authenticated', c.oid, 'INSERT')
        or has_table_privilege('authenticated', c.oid, 'UPDATE')
        or has_table_privilege('authenticated', c.oid, 'DELETE')
        or has_table_privilege('authenticated', c.oid, 'TRUNCATE'))),
  0,
  'authenticated: holds no INSERT/UPDATE/DELETE/TRUNCATE on any public relation'
);

select ok(not has_table_privilege('authenticated', 'public.profiles', 'INSERT'),
  'authenticated: cannot INSERT profiles');
select ok(not has_table_privilege('authenticated', 'public.profiles', 'UPDATE'),
  'authenticated: cannot UPDATE profiles');
select ok(not has_table_privilege('authenticated', 'public.profiles', 'DELETE'),
  'authenticated: cannot DELETE profiles');
select ok(not has_table_privilege('authenticated', 'public.sessions', 'INSERT'),
  'authenticated: cannot INSERT sessions');
select ok(not has_table_privilege('authenticated', 'public.sessions', 'UPDATE'),
  'authenticated: cannot UPDATE sessions');
select ok(not has_table_privilege('authenticated', 'public.sessions', 'DELETE'),
  'authenticated: cannot DELETE sessions');
select ok(not has_table_privilege('authenticated', 'public.session_samples', 'INSERT'),
  'authenticated: cannot INSERT session_samples');
select ok(not has_table_privilege('authenticated', 'public.session_metrics', 'INSERT'),
  'authenticated: cannot INSERT session_metrics');
select ok(not has_table_privilege('authenticated', 'public.instruments', 'INSERT'),
  'authenticated: cannot INSERT catalog (instruments)');
select ok(not has_table_privilege('authenticated', 'public.exercise_revisions', 'UPDATE'),
  'authenticated: cannot UPDATE catalog (exercise_revisions)');
select ok(not has_table_privilege('authenticated', 'public.target_string_actions', 'DELETE'),
  'authenticated: cannot DELETE catalog (target_string_actions)');

-- ============================================================
-- idempotency_records: no client reach                [2 assertions]
-- ============================================================
select ok(
  not has_table_privilege('authenticated', 'public.idempotency_records', 'SELECT'),
  'authenticated: no SELECT on idempotency_records'
);

select is(
  (select count(*)::int from pg_catalog.pg_policies
    where schemaname = 'public' and tablename = 'idempotency_records'),
  0,
  'idempotency_records: zero policies (default-deny under RLS)'
);

-- ============================================================
-- anon: nothing                                       [1 assertion]
-- ============================================================
select is(
  (select count(*)::int
     from pg_catalog.pg_class c
     join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'v')
      and has_table_privilege('anon', c.oid, 'SELECT')),
  0,
  'anon: holds no SELECT on any public relation'
);

-- ============================================================
-- Function EXECUTE surface                            [3 assertions]
-- ============================================================
select is(
  (select count(*)::int
     from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  0,
  'authenticated: no EXECUTE on any function in public'
);

select is(
  (select count(*)::int
     from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('anon', p.oid, 'EXECUTE')),
  0,
  'anon: no EXECUTE on any function in public'
);

select is(
  (
    select count(*)::int
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    cross join lateral pg_catalog.aclexplode(
      coalesce(
        p.proacl,
        pg_catalog.acldefault('f'::"char", p.proowner)
      )
    ) a
    where n.nspname = 'public'
      and a.grantee = 0
      and a.privilege_type = 'EXECUTE'
  ),
  0,
  'PUBLIC: no EXECUTE ACL entry on any function in public'
);

-- ============================================================
-- Sequence surface                                    [1 assertion]
-- ============================================================
select is(
  (select count(*)::int
     from pg_catalog.pg_class c
     join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'S'
      and (has_sequence_privilege('authenticated', c.oid, 'USAGE')
        or has_sequence_privilege('anon', c.oid, 'USAGE'))),
  0,
  'sequences: no client role holds USAGE on any sequence in public'
);

-- ============================================================
-- RLS enabled AND forced                              [2 assertions]
-- ============================================================
select is(
  (select count(*)::int
     from pg_catalog.pg_class c
     join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and not c.relrowsecurity),
  0,
  'RLS: enabled on every table in public'
);

select is(
  (select count(*)::int
     from pg_catalog.pg_class c
     join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and not c.relforcerowsecurity),
  0,
  'RLS: FORCED on every table in public'
);

-- ============================================================
-- security_invoker views                              [2 assertions]
-- ============================================================
select ok(
  (select 'security_invoker=true' = any(c.reloptions)
     from pg_catalog.pg_class c
     join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'v_user_practice_summary'),
  'v_user_practice_summary: security_invoker = true'
);

select ok(
  (select 'security_invoker=true' = any(c.reloptions)
     from pg_catalog.pg_class c
     join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'v_latest_published_revision'),
  'v_latest_published_revision: security_invoker = true'
);

-- ============================================================
-- Policy surface                                      [1 assertion]
-- ============================================================
select is(
  (select count(*)::int from pg_catalog.pg_policies
    where schemaname = 'public' and cmd <> 'SELECT'),
  0,
  'policies: no non-SELECT policy exists in public'
);

select finish();

rollback;
