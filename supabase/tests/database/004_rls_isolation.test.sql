-- ============================================================
-- 004 — RLS isolation via JWT-claim impersonation
-- Phase 1.
--
-- Sets BOTH request.jwt.claim.sub and request.jwt.claims so auth.uid()
-- resolves regardless of which branch the local stack's definition uses.
-- An explicit guard asserts a non-NULL auth.uid() BEFORE any isolation
-- assertion; a NULL uid would make every "cannot read" assertion pass
-- vacuously.
--
-- Plan = 22 assertions.
-- ============================================================
begin;

create extension if not exists pgtap with schema extensions;

select plan(22);

-- ------------------------------------------------------------
-- Fixtures, created as the admin connection.
-- ------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email,
                        encrypted_password, created_at, updated_at)
values
  ('dddddddd-0000-4000-8000-00000000000a',
   '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated',
   't004-a@fretvision.invalid', '', now(), now()),
  ('dddddddd-0000-4000-8000-00000000000b',
   '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated',
   't004-b@fretvision.invalid', '', now(), now());

insert into public.profiles (user_id, display_name, fretting_hand) values
  ('dddddddd-0000-4000-8000-00000000000a', 'User A', 'left'),
  ('dddddddd-0000-4000-8000-00000000000b', 'User B', 'right');

create or replace function pg_temp.t004_completed_session(
  p_session uuid, p_user uuid) returns void
  language plpgsql as $$
begin
  insert into public.sessions
    (id, user_id, exercise_revision_id, target_position_revision_id,
     fretting_hand_snapshot, accuracy_metric_version, calibration_method,
     declared_interval_ms)
  values (p_session, p_user,
          '44444444-4444-4444-8444-000000000001',
          '55555555-5555-4555-8555-000000000001',
          'left', 1, 'manual_4pt', 3000);

  update public.sessions
     set lifecycle = 'active', activated_at = now()
   where id = p_session;

  insert into public.session_samples
    (id, session_id, seq, is_valid, invalid_reason,
     placement_accuracy, confidence, interval_end_offset_ms)
  values
    (pg_catalog.gen_random_uuid(), p_session, 0, true, null, 0.9, 0.9, 3000),
    (pg_catalog.gen_random_uuid(), p_session, 1, false, 'occlusion',
     null, null, 6000);

  update public.sessions
     set lifecycle = 'completed',
         active_duration_ms = 300000,
         ended_at_client = now(),
         completion_received_at = now(),
         scoring_status = 'scored'
   where id = p_session;

  insert into public.session_metrics
    (session_id, placement_accuracy, confidence_mean, valid_sample_ratio,
     coverage_duration_ms, expected_sample_count, submitted_sample_count,
     valid_sample_count)
  values (p_session, 0.9, 0.9, 1.0, 300000, 1, 2, 1);

  insert into public.session_invalid_reason_counts (session_id, reason, count)
  values (p_session, 'occlusion', 1);
end $$;

select pg_temp.t004_completed_session(
  'dddddddd-0000-4000-8000-000000000100',
  'dddddddd-0000-4000-8000-00000000000a');

select pg_temp.t004_completed_session(
  'dddddddd-0000-4000-8000-000000000200',
  'dddddddd-0000-4000-8000-00000000000b');

-- An UNPUBLISHED revision + target, to prove catalog RLS hides drafts.
insert into public.exercise_revisions
  (id, exercise_id, revision_no, title_snapshot, instructions,
   instrument_id_snapshot, published, published_at)
values ('dddddddd-0000-4000-8000-000000000300',
        '33333333-3333-4333-8333-000000000001', 2,
        'Draft Title', 'Draft instructions',
        '11111111-1111-4111-8111-000000000001', false, null);

insert into public.target_position_revisions (id, exercise_revision_id)
values ('dddddddd-0000-4000-8000-000000000301',
        'dddddddd-0000-4000-8000-000000000300');

insert into public.target_string_actions
  (target_position_revision_id, string_no, action, fret_no, finger_no)
values
  ('dddddddd-0000-4000-8000-000000000301', 1, 'open', null, null),
  ('dddddddd-0000-4000-8000-000000000301', 2, 'open', null, null),
  ('dddddddd-0000-4000-8000-000000000301', 3, 'open', null, null),
  ('dddddddd-0000-4000-8000-000000000301', 4, 'open', null, null),
  ('dddddddd-0000-4000-8000-000000000301', 5, 'open', null, null),
  ('dddddddd-0000-4000-8000-000000000301', 6, 'open', null, null);

insert into public.idempotency_records
  (user_id, operation, idempotency_key, request_hash, state, expires_at)
values ('dddddddd-0000-4000-8000-00000000000a',
        'start_session', 't004-key-aaaaaaaa',
        repeat('a', 64), 'processing', now() + interval '1 day');

-- ============================================================
-- Impersonate User A                                 [19 assertions]
-- ============================================================
set local role authenticated;
set local request.jwt.claim.sub = 'dddddddd-0000-4000-8000-00000000000a';
set local request.jwt.claims =
  '{"sub":"dddddddd-0000-4000-8000-00000000000a","role":"authenticated"}';

select is(
  (select auth.uid()),
  'dddddddd-0000-4000-8000-00000000000a'::uuid,
  'GUARD: auth.uid() resolves to User A'
);

select is(
  (select count(*)::int from public.profiles), 1,
  'A: sees exactly one profile (own)'
);

select is(
  (select user_id from public.profiles),
  'dddddddd-0000-4000-8000-00000000000a'::uuid,
  'A: the visible profile is A''s'
);

select is(
  (select count(*)::int from public.sessions), 1,
  'A: sees exactly one session (own)'
);

select is(
  (select count(*)::int from public.sessions
    where id = 'dddddddd-0000-4000-8000-000000000200'), 0,
  'A: cannot see B''s session'
);

select is(
  (select count(*)::int from public.session_samples), 2,
  'A: sees only own session_samples'
);

select is(
  (select count(*)::int from public.session_samples
    where session_id = 'dddddddd-0000-4000-8000-000000000200'), 0,
  'A: cannot see B''s samples'
);

select is(
  (select count(*)::int from public.session_metrics), 1,
  'A: sees only own session_metrics'
);

select is(
  (select count(*)::int from public.session_metrics
    where session_id = 'dddddddd-0000-4000-8000-000000000200'), 0,
  'A: cannot see B''s metrics'
);

select is(
  (select count(*)::int from public.session_invalid_reason_counts), 1,
  'A: sees only own invalid-reason counts'
);

select is(
  (select count(*)::int from public.session_invalid_reason_counts
    where session_id = 'dddddddd-0000-4000-8000-000000000200'), 0,
  'A: cannot see B''s invalid-reason counts'
);

select is(
  (select count(*)::int from public.v_user_practice_summary), 1,
  'A: v_user_practice_summary returns exactly one row'
);

select is(
  (select user_id from public.v_user_practice_summary),
  'dddddddd-0000-4000-8000-00000000000a'::uuid,
  'A: the summary row is A''s'
);

select is(
  (select count(*)::int from public.exercise_revisions
    where id = '44444444-4444-4444-8444-000000000001'), 1,
  'A: seeded published revision is readable'
);

select is(
  (select count(*)::int from public.exercise_revisions
    where id = 'dddddddd-0000-4000-8000-000000000300'), 0,
  'A: unpublished revision is invisible'
);

select is(
  (select count(*)::int from public.target_position_revisions
    where id = 'dddddddd-0000-4000-8000-000000000301'), 0,
  'A: target under an unpublished revision is invisible'
);

select is(
  (select count(*)::int from public.target_string_actions
    where target_position_revision_id = 'dddddddd-0000-4000-8000-000000000301'), 0,
  'A: string actions under an unpublished revision are invisible'
);

select is(
  (select count(*)::int from public.v_latest_published_revision), 1,
  'A: v_latest_published_revision exposes only the published revision'
);

select throws_ok(
  $$select 1 from public.idempotency_records$$,
  '42501', null,
  'A: SELECT on idempotency_records denied (no grant)'
);

-- ============================================================
-- Switch to User B                                    [3 assertions]
-- ============================================================
set local request.jwt.claim.sub = 'dddddddd-0000-4000-8000-00000000000b';
set local request.jwt.claims =
  '{"sub":"dddddddd-0000-4000-8000-00000000000b","role":"authenticated"}';

select is(
  (select auth.uid()),
  'dddddddd-0000-4000-8000-00000000000b'::uuid,
  'GUARD: auth.uid() resolves to User B'
);

select is(
  (select count(*)::int from public.sessions
    where id = 'dddddddd-0000-4000-8000-000000000100'), 0,
  'B: cannot see A''s session'
);

select is(
  (select user_id from public.v_user_practice_summary),
  'dddddddd-0000-4000-8000-00000000000b'::uuid,
  'B: v_user_practice_summary returns only B''s row'
);

reset role;

select finish();

rollback;
