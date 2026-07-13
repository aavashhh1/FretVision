-- ============================================================
-- 003 — Session lifecycle, sample locking, metrics invariants
-- Phase 1.
--
-- Plan = 28 assertions.
--
-- Isolation strategy:
--   * Immediate-error assertions use pgTAP throws_ok() directly.
--   * Deferred-trigger scenarios run inside pg_temp.t003_case_result().
--     Its exception block creates a PostgreSQL subtransaction.
--   * Each scenario always raises and catches a private P0001 sentinel
--     after success, so all scenario DML is rolled back without rolling
--     back the surrounding pgTAP assertion or its test counter.
--
-- Do not wrap pgTAP assertions in SAVEPOINT ... ROLLBACK TO blocks:
-- rolling back the savepoint also rolls back pgTAP bookkeeping.
-- ============================================================
begin;

create extension if not exists pgtap with schema extensions;

select plan(28);

-- ------------------------------------------------------------
-- Fixtures
-- ------------------------------------------------------------
insert into auth.users (
  id,
  instance_id,
  aud,
  role,
  email,
  encrypted_password,
  created_at,
  updated_at
)
values (
  'cccccccc-0000-4000-8000-00000000000a',
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  't003@fretvision.invalid',
  '',
  now(),
  now()
);

insert into public.profiles (
  user_id,
  display_name,
  fretting_hand
)
values (
  'cccccccc-0000-4000-8000-00000000000a',
  'T003 User',
  'left'
);

create or replace function pg_temp.t003_new_session(p_id uuid)
returns void
language plpgsql
as $$
begin
  insert into public.sessions (
    id,
    user_id,
    exercise_revision_id,
    target_position_revision_id,
    fretting_hand_snapshot,
    accuracy_metric_version,
    calibration_method,
    declared_interval_ms
  )
  values (
    p_id,
    'cccccccc-0000-4000-8000-00000000000a',
    '44444444-4444-4444-8444-000000000001',
    '55555555-5555-4555-8555-000000000001',
    'left',
    1,
    'manual_4pt',
    3000
  );
end
$$;

-- submitted = 3, valid = 2 => reason-count sum must be 1.
create or replace function pg_temp.t003_complete(p_session uuid)
returns void
language plpgsql
as $$
begin
  update public.sessions
     set lifecycle = 'completed',
         active_duration_ms = 12000,
         ended_at_client = now(),
         completion_received_at = now(),
         scoring_status = 'insufficient_coverage'
   where id = p_session;

  insert into public.session_metrics (
    session_id,
    placement_accuracy,
    confidence_mean,
    valid_sample_ratio,
    coverage_duration_ms,
    expected_sample_count,
    submitted_sample_count,
    valid_sample_count
  )
  values (
    p_session,
    0.85,
    0.925,
    0.5,
    6000,
    4,
    3,
    2
  );

  insert into public.session_invalid_reason_counts (
    session_id,
    reason,
    count
  )
  values (
    p_session,
    'low_confidence',
    1
  );
end
$$;

-- ------------------------------------------------------------
-- Run one stateful scenario in an isolated PL/pgSQL subtransaction.
--
-- Return values:
--   00000  scenario completed without an unexpected exception
--   23514  expected check_violation from a tested invariant
--   other  unexpected SQLSTATE, which makes the pgTAP is() fail
--   0      special scalar result for abandon_metrics_count
--
-- The private P0001 exception intentionally aborts the inner block
-- after a successful scenario. PostgreSQL rolls back all scenario DML,
-- while v_result remains available to the exception handler.
-- ------------------------------------------------------------
create or replace function pg_temp.t003_case_result(p_case text)
returns text
language plpgsql
as $$
declare
  v_result text := '00000';
begin
  begin
    set constraints all deferred;

    case p_case
      when 'completion_valid' then
        perform pg_temp.t003_complete(
          'cccccccc-0000-4000-8000-000000000100'
        );
        set constraints all immediate;

      when 'protect_metrics_delete' then
        perform pg_temp.t003_complete(
          'cccccccc-0000-4000-8000-000000000100'
        );
        set constraints all immediate;

        -- This must fail immediately through
        -- public.trg_protect_completed_metrics().
        delete from public.session_metrics
         where session_id = 'cccccccc-0000-4000-8000-000000000100';

      when 'terminal_insert' then
        perform pg_temp.t003_complete(
          'cccccccc-0000-4000-8000-000000000100'
        );
        set constraints all immediate;

        insert into public.session_samples (
          id,
          session_id,
          seq,
          is_valid,
          invalid_reason,
          placement_accuracy,
          confidence,
          interval_end_offset_ms
        )
        values (
          'cccccccc-0000-4000-8000-000000000203',
          'cccccccc-0000-4000-8000-000000000100',
          3,
          true,
          null,
          0.5,
          0.5,
          12000
        );

      when 'terminal_update' then
        perform pg_temp.t003_complete(
          'cccccccc-0000-4000-8000-000000000100'
        );
        set constraints all immediate;

        update public.session_samples
           set placement_accuracy = 0.1
         where id = 'cccccccc-0000-4000-8000-000000000200';

      when 'terminal_delete' then
        perform pg_temp.t003_complete(
          'cccccccc-0000-4000-8000-000000000100'
        );
        set constraints all immediate;

        delete from public.session_samples
         where id = 'cccccccc-0000-4000-8000-000000000200';

      when 'no_metrics_statement' then
        -- Do not force deferred constraints here. This case proves that
        -- the transition statement itself succeeds.
        update public.sessions
           set lifecycle = 'completed',
               active_duration_ms = 12000,
               ended_at_client = now(),
               completion_received_at = now(),
               scoring_status = 'insufficient_coverage'
         where id = 'cccccccc-0000-4000-8000-000000000100';

      when 'no_metrics_deferred' then
        update public.sessions
           set lifecycle = 'completed',
               active_duration_ms = 12000,
               ended_at_client = now(),
               completion_received_at = now(),
               scoring_status = 'insufficient_coverage'
         where id = 'cccccccc-0000-4000-8000-000000000100';

        set constraints all immediate;

      when 'reason_bad' then
        update public.sessions
           set lifecycle = 'completed',
               active_duration_ms = 12000,
               ended_at_client = now(),
               completion_received_at = now(),
               scoring_status = 'insufficient_coverage'
         where id = 'cccccccc-0000-4000-8000-000000000100';

        insert into public.session_metrics (
          session_id,
          placement_accuracy,
          confidence_mean,
          valid_sample_ratio,
          coverage_duration_ms,
          expected_sample_count,
          submitted_sample_count,
          valid_sample_count
        )
        values (
          'cccccccc-0000-4000-8000-000000000100',
          0.85,
          0.925,
          0.5,
          6000,
          4,
          3,
          2
        );

        insert into public.session_invalid_reason_counts (
          session_id,
          reason,
          count
        )
        values (
          'cccccccc-0000-4000-8000-000000000100',
          'low_confidence',
          5
        );

        set constraints all immediate;

      when 'reason_zero' then
        update public.sessions
           set lifecycle = 'completed',
               active_duration_ms = 12000,
               ended_at_client = now(),
               completion_received_at = now(),
               scoring_status = 'insufficient_coverage'
         where id = 'cccccccc-0000-4000-8000-000000000100';

        insert into public.session_metrics (
          session_id,
          placement_accuracy,
          confidence_mean,
          valid_sample_ratio,
          coverage_duration_ms,
          expected_sample_count,
          submitted_sample_count,
          valid_sample_count
        )
        values (
          'cccccccc-0000-4000-8000-000000000100',
          0.85,
          0.925,
          0.5,
          6000,
          4,
          2,
          2
        );

        set constraints all immediate;

      when 'abandon_valid' then
        update public.sessions
           set lifecycle = 'abandoned',
               scoring_status = 'insufficient_coverage'
         where id = 'cccccccc-0000-4000-8000-000000000100';

      when 'abandon_scored' then
        update public.sessions
           set lifecycle = 'abandoned',
               scoring_status = 'insufficient_coverage'
         where id = 'cccccccc-0000-4000-8000-000000000100';

        update public.sessions
           set scoring_status = 'scored'
         where id = 'cccccccc-0000-4000-8000-000000000100';

      when 'abandon_metrics_count' then
        update public.sessions
           set lifecycle = 'abandoned',
               scoring_status = 'insufficient_coverage'
         where id = 'cccccccc-0000-4000-8000-000000000100';

        select count(*)::text
          into v_result
          from public.session_metrics
         where session_id = 'cccccccc-0000-4000-8000-000000000100';

      when 'abandon_deferred' then
        update public.sessions
           set lifecycle = 'abandoned',
               scoring_status = 'insufficient_coverage'
         where id = 'cccccccc-0000-4000-8000-000000000100';

        set constraints all immediate;

      when 'cascade' then
        perform pg_temp.t003_complete(
          'cccccccc-0000-4000-8000-000000000100'
        );
        set constraints all immediate;

        delete from auth.users
         where id = 'cccccccc-0000-4000-8000-00000000000a';

        set constraints all immediate;

      else
        raise exception 'unknown t003 case: %', p_case
          using errcode = '22023';
    end case;

    -- Force rollback of all scenario DML after a successful case.
    raise exception 't003 isolated scenario rollback'
      using errcode = 'P0001';

  exception
    when sqlstate 'P0001' then
      return v_result;
    when others then
      return sqlstate;
  end;
end
$$;

-- ============================================================
-- trg_session_born_created                            [6 assertions]
-- ============================================================
select throws_ok(
  $$insert into public.sessions
      (user_id, exercise_revision_id, target_position_revision_id,
       lifecycle, fretting_hand_snapshot, accuracy_metric_version,
       calibration_method, declared_interval_ms, activated_at)
    values ('cccccccc-0000-4000-8000-00000000000a',
            '44444444-4444-4444-8444-000000000001',
            '55555555-5555-4555-8555-000000000001',
            'active', 'left', 1, 'manual_4pt', 3000, now())$$,
  '23514',
  null,
  'born_created: INSERT with lifecycle = active rejected'
);

select throws_ok(
  $$insert into public.sessions
      (user_id, exercise_revision_id, target_position_revision_id,
       fretting_hand_snapshot, accuracy_metric_version,
       calibration_method, declared_interval_ms, activated_at)
    values ('cccccccc-0000-4000-8000-00000000000a',
            '44444444-4444-4444-8444-000000000001',
            '55555555-5555-4555-8555-000000000001',
            'left', 1, 'manual_4pt', 3000, now())$$,
  '23514',
  null,
  'born_created: INSERT with non-null activated_at rejected'
);

select throws_ok(
  $$insert into public.sessions
      (user_id, exercise_revision_id, target_position_revision_id,
       fretting_hand_snapshot, accuracy_metric_version,
       calibration_method, declared_interval_ms, active_duration_ms)
    values ('cccccccc-0000-4000-8000-00000000000a',
            '44444444-4444-4444-8444-000000000001',
            '55555555-5555-4555-8555-000000000001',
            'left', 1, 'manual_4pt', 3000, 60000)$$,
  '23514',
  null,
  'born_created: INSERT with non-null active_duration_ms rejected'
);

select throws_ok(
  $$insert into public.sessions
      (user_id, exercise_revision_id, target_position_revision_id,
       fretting_hand_snapshot, accuracy_metric_version,
       calibration_method, declared_interval_ms, ended_at_client)
    values ('cccccccc-0000-4000-8000-00000000000a',
            '44444444-4444-4444-8444-000000000001',
            '55555555-5555-4555-8555-000000000001',
            'left', 1, 'manual_4pt', 3000, now())$$,
  '23514',
  null,
  'born_created: INSERT with non-null ended_at_client rejected'
);

select throws_ok(
  $$insert into public.sessions
      (user_id, exercise_revision_id, target_position_revision_id,
       fretting_hand_snapshot, accuracy_metric_version,
       calibration_method, declared_interval_ms, sync_delay_ms)
    values ('cccccccc-0000-4000-8000-00000000000a',
            '44444444-4444-4444-8444-000000000001',
            '55555555-5555-4555-8555-000000000001',
            'left', 1, 'manual_4pt', 3000, 500)$$,
  '23514',
  null,
  'born_created: INSERT with non-null sync_delay_ms rejected'
);

select lives_ok(
  $$select pg_temp.t003_new_session(
      'cccccccc-0000-4000-8000-000000000100'
    )$$,
  'born_created: clean created session accepted'
);

-- ============================================================
-- trg_session_transition                              [4 assertions]
-- ============================================================
select throws_ok(
  $$update public.sessions
       set lifecycle = 'completed',
           activated_at = now(),
           active_duration_ms = 60000,
           ended_at_client = now(),
           completion_received_at = now(),
           scoring_status = 'scored'
     where id = 'cccccccc-0000-4000-8000-000000000100'$$,
  '23514',
  null,
  'transition: created -> completed rejected'
);

select throws_ok(
  $$update public.sessions
       set lifecycle = 'abandoned',
           activated_at = now(),
           scoring_status = 'insufficient_coverage'
     where id = 'cccccccc-0000-4000-8000-000000000100'$$,
  '23514',
  null,
  'transition: created -> abandoned rejected'
);

select lives_ok(
  $$update public.sessions
       set lifecycle = 'active',
           activated_at = now()
     where id = 'cccccccc-0000-4000-8000-000000000100'$$,
  'transition: created -> active accepted'
);

select throws_ok(
  $$update public.sessions
       set lifecycle = 'created'
     where id = 'cccccccc-0000-4000-8000-000000000100'$$,
  '23514',
  null,
  'transition: active -> created rejected'
);

-- ============================================================
-- Sample writes and identity immutability             [3 assertions]
-- ============================================================
select lives_ok(
  $$insert into public.session_samples
      (id, session_id, seq, is_valid, invalid_reason,
       placement_accuracy, confidence, interval_end_offset_ms)
    values ('cccccccc-0000-4000-8000-000000000200',
            'cccccccc-0000-4000-8000-000000000100',
            0, true, null, 0.80, 0.90, 3000)$$,
  'samples: INSERT into an active session accepted'
);

insert into public.session_samples (
  id,
  session_id,
  seq,
  is_valid,
  invalid_reason,
  placement_accuracy,
  confidence,
  interval_end_offset_ms
)
values
  (
    'cccccccc-0000-4000-8000-000000000201',
    'cccccccc-0000-4000-8000-000000000100',
    1,
    true,
    null,
    0.90,
    0.95,
    6000
  ),
  (
    'cccccccc-0000-4000-8000-000000000202',
    'cccccccc-0000-4000-8000-000000000100',
    2,
    false,
    'low_confidence',
    null,
    null,
    9000
  );

select throws_ok(
  $$update public.session_samples
       set seq = 99
     where id = 'cccccccc-0000-4000-8000-000000000200'$$,
  '23514',
  null,
  'samples: changing seq rejected'
);

select pg_temp.t003_new_session(
  'cccccccc-0000-4000-8000-000000000101'
);

select throws_ok(
  $$update public.session_samples
       set session_id = 'cccccccc-0000-4000-8000-000000000101'
     where id = 'cccccccc-0000-4000-8000-000000000200'$$,
  '23514',
  null,
  'samples: changing session_id rejected'
);

-- ============================================================
-- trg_metrics_only_completed                          [1 assertion]
-- ============================================================
select throws_ok(
  $$insert into public.session_metrics
      (session_id, placement_accuracy, confidence_mean, valid_sample_ratio,
       coverage_duration_ms, expected_sample_count, submitted_sample_count,
       valid_sample_count)
    values ('cccccccc-0000-4000-8000-000000000100',
            0.85, 0.92, 0.5, 6000, 4, 3, 2)$$,
  '23514',
  null,
  'metrics: INSERT for an active session rejected'
);

-- ============================================================
-- Well-formed completion                              [1 assertion]
-- ============================================================
select is(
  pg_temp.t003_case_result('completion_valid'),
  '00000'::text,
  'completion: session + metrics + reason counts satisfy all deferred checks'
);

-- ============================================================
-- protect_completed_metrics                           [1 assertion]
-- ============================================================
select is(
  pg_temp.t003_case_result('protect_metrics_delete'),
  '23514'::text,
  'metrics: DELETE of a completed session metrics row is rejected immediately'
);

-- ============================================================
-- Terminal-session sample lock                        [3 assertions]
-- ============================================================
select is(
  pg_temp.t003_case_result('terminal_insert'),
  '23514'::text,
  'terminal: sample INSERT into a completed session rejected'
);

select is(
  pg_temp.t003_case_result('terminal_update'),
  '23514'::text,
  'terminal: sample UPDATE on a completed session rejected'
);

select is(
  pg_temp.t003_case_result('terminal_delete'),
  '23514'::text,
  'terminal: sample DELETE on a completed session rejected'
);

-- ============================================================
-- completed_needs_metrics (deferred)                  [2 assertions]
-- ============================================================
select is(
  pg_temp.t003_case_result('no_metrics_statement'),
  '00000'::text,
  'deferred: UPDATE to completed without metrics succeeds at statement time'
);

select is(
  pg_temp.t003_case_result('no_metrics_deferred'),
  '23514'::text,
  'deferred: completed session with no metrics row fails when constraints become immediate'
);

-- ============================================================
-- reason_counts_sum (deferred)                        [2 assertions]
-- ============================================================
select is(
  pg_temp.t003_case_result('reason_bad'),
  '23514'::text,
  'reason_counts: sum 5 <> submitted(3) - valid(2) rejected at deferred check'
);

select is(
  pg_temp.t003_case_result('reason_zero'),
  '00000'::text,
  'reason_counts: submitted = valid with zero reason rows accepted'
);

-- ============================================================
-- Abandonment                                         [4 assertions]
-- ============================================================
select is(
  pg_temp.t003_case_result('abandon_valid'),
  '00000'::text,
  'abandon: active -> abandoned accepted'
);

select is(
  pg_temp.t003_case_result('abandon_scored'),
  '23514'::text,
  'abandon: scoring_status = scored on an abandoned session rejected'
);

select is(
  pg_temp.t003_case_result('abandon_metrics_count'),
  '0'::text,
  'abandon: abandoned session carries no metrics row'
);

select is(
  pg_temp.t003_case_result('abandon_deferred'),
  '00000'::text,
  'abandon: completed_needs_metrics does not fire for an abandoned session'
);

-- ============================================================
-- Parent-user cascade                                 [1 assertion]
-- ============================================================
select is(
  pg_temp.t003_case_result('cascade'),
  '00000'::text,
  'cascade: user delete cascades session + metrics without false protection violation'
);

select finish();

rollback;