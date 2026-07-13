-- ============================================================
-- 001 — Schema invariants (CHECK / UNIQUE / FK)
-- Phase 1. Migrations 0001-0007 only. No fretvision_app required.
-- Every fixture is created inside the transaction and rolled back.
-- Plan = 32 assertions.
-- ============================================================
begin;

create extension if not exists pgtap with schema extensions;

select plan(32);

-- ------------------------------------------------------------
-- Fixtures. Deterministic UUIDs, distinct from the 0007 seed.
-- ------------------------------------------------------------
insert into public.instruments (id, name, string_count)
values ('aaaaaaaa-0000-4000-8000-000000000001', 'T001 Six String', 6);

insert into public.lessons (id, title, sort_order)
values ('aaaaaaaa-0000-4000-8000-000000000002', 'T001 Lesson', 0);

insert into public.exercises (id, lesson_id, instrument_id, title)
values ('aaaaaaaa-0000-4000-8000-000000000003',
        'aaaaaaaa-0000-4000-8000-000000000002',
        'aaaaaaaa-0000-4000-8000-000000000001',
        'T001 Exercise');

insert into public.exercise_revisions
  (id, exercise_id, revision_no, title_snapshot, instructions,
   instrument_id_snapshot, published, published_at)
values ('aaaaaaaa-0000-4000-8000-000000000004',
        'aaaaaaaa-0000-4000-8000-000000000003',
        1, 'T001', 'T001 instructions',
        'aaaaaaaa-0000-4000-8000-000000000001', false, null);

insert into public.target_position_revisions (id, exercise_revision_id)
values ('aaaaaaaa-0000-4000-8000-000000000005',
        'aaaaaaaa-0000-4000-8000-000000000004');

-- Second revision: used for the composite-FK mismatch assertion.
insert into public.exercise_revisions
  (id, exercise_id, revision_no, title_snapshot, instructions,
   instrument_id_snapshot, published, published_at)
values ('aaaaaaaa-0000-4000-8000-000000000006',
        'aaaaaaaa-0000-4000-8000-000000000003',
        2, 'T001b', 'T001b instructions',
        'aaaaaaaa-0000-4000-8000-000000000001', false, null);

insert into auth.users (id, instance_id, aud, role, email,
                        encrypted_password, created_at, updated_at)
values ('aaaaaaaa-0000-4000-8000-00000000000a',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated',
        't001@fretvision.invalid', '', now(), now());

insert into public.profiles (user_id, display_name, fretting_hand)
values ('aaaaaaaa-0000-4000-8000-00000000000a', 'T001 User', 'left');

-- ============================================================
-- instruments.string_count = 6                       [3 assertions]
-- ============================================================
select throws_ok(
  $$insert into public.instruments (name, string_count)
    values ('T001 Four String', 4)$$,
  '23514', null,
  'instruments: string_count = 4 rejected'
);

select throws_ok(
  $$insert into public.instruments (name, string_count)
    values ('T001 Twelve String', 12)$$,
  '23514', null,
  'instruments: string_count = 12 rejected'
);

select lives_ok(
  $$insert into public.instruments (id, name, string_count)
    values ('aaaaaaaa-0000-4000-8000-0000000000ff', 'T001 Valid Six', 6)$$,
  'instruments: string_count = 6 accepted'
);

-- ============================================================
-- chk_action_shape: fretted branch                   [6 assertions]
-- ============================================================
select throws_ok(
  $$insert into public.target_string_actions
      (target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000005', 1, 'fretted', null, 3)$$,
  '23514', null,
  'tsa: fretted with NULL fret_no rejected'
);

select throws_ok(
  $$insert into public.target_string_actions
      (target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000005', 1, 'fretted', 5, null)$$,
  '23514', null,
  'tsa: fretted with NULL finger_no rejected'
);

select throws_ok(
  $$insert into public.target_string_actions
      (target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000005', 1, 'fretted', 0, 3)$$,
  '23514', null,
  'tsa: fretted fret_no = 0 rejected (below range)'
);

select throws_ok(
  $$insert into public.target_string_actions
      (target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000005', 1, 'fretted', 13, 3)$$,
  '23514', null,
  'tsa: fretted fret_no = 13 rejected (above range)'
);

select throws_ok(
  $$insert into public.target_string_actions
      (target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000005', 1, 'fretted', 5, 5)$$,
  '23514', null,
  'tsa: fretted finger_no = 5 rejected (above range)'
);

select lives_ok(
  $$insert into public.target_string_actions
      (id, target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000101',
            'aaaaaaaa-0000-4000-8000-000000000005', 1, 'fretted', 12, 4)$$,
  'tsa: fretted at boundary fret 12 / finger 4 accepted'
);

-- ============================================================
-- chk_action_shape: open / muted / ignored branch     [5 assertions]
-- ============================================================
select throws_ok(
  $$insert into public.target_string_actions
      (target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000005', 2, 'open', 3, null)$$,
  '23514', null,
  'tsa: open with non-null fret_no rejected'
);

select throws_ok(
  $$insert into public.target_string_actions
      (target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000005', 2, 'muted', null, 2)$$,
  '23514', null,
  'tsa: muted with non-null finger_no rejected'
);

select throws_ok(
  $$insert into public.target_string_actions
      (target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000005', 2, 'ignored', 1, 1)$$,
  '23514', null,
  'tsa: ignored with non-null fret/finger rejected'
);

select lives_ok(
  $$insert into public.target_string_actions
      (id, target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000102',
            'aaaaaaaa-0000-4000-8000-000000000005', 2, 'open', null, null)$$,
  'tsa: open with NULL fret/finger accepted'
);

select lives_ok(
  $$insert into public.target_string_actions
      (id, target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000103',
            'aaaaaaaa-0000-4000-8000-000000000005', 3, 'fretted', 12, 4)$$,
  'tsa: barre (finger reused on another string) accepted'
);

-- ============================================================
-- uq_tsa_string                                       [1 assertion]
-- ============================================================
select throws_ok(
  $$insert into public.target_string_actions
      (target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('aaaaaaaa-0000-4000-8000-000000000005', 1, 'open', null, null)$$,
  '23505', null,
  'tsa: duplicate (target, string_no) rejected by uq_tsa_string'
);

-- ============================================================
-- sessions: composite FK + interval band              [3 assertions]
-- ============================================================
select throws_ok(
  $$insert into public.sessions
      (user_id, exercise_revision_id, target_position_revision_id,
       fretting_hand_snapshot, accuracy_metric_version, calibration_method,
       declared_interval_ms)
    values ('aaaaaaaa-0000-4000-8000-00000000000a',
            'aaaaaaaa-0000-4000-8000-000000000006',
            'aaaaaaaa-0000-4000-8000-000000000005',
            'left', 1, 'manual_4pt', 3000)$$,
  '23503', null,
  'sessions: mismatched (exercise_revision, target) rejected by composite FK'
);

select throws_ok(
  $$insert into public.sessions
      (user_id, exercise_revision_id, target_position_revision_id,
       fretting_hand_snapshot, accuracy_metric_version, calibration_method,
       declared_interval_ms)
    values ('aaaaaaaa-0000-4000-8000-00000000000a',
            'aaaaaaaa-0000-4000-8000-000000000004',
            'aaaaaaaa-0000-4000-8000-000000000005',
            'left', 1, 'manual_4pt', 1999)$$,
  '23514', null,
  'sessions: declared_interval_ms = 1999 rejected'
);

select throws_ok(
  $$insert into public.sessions
      (user_id, exercise_revision_id, target_position_revision_id,
       fretting_hand_snapshot, accuracy_metric_version, calibration_method,
       declared_interval_ms)
    values ('aaaaaaaa-0000-4000-8000-00000000000a',
            'aaaaaaaa-0000-4000-8000-000000000004',
            'aaaaaaaa-0000-4000-8000-000000000005',
            'left', 1, 'manual_4pt', 5001)$$,
  '23514', null,
  'sessions: declared_interval_ms = 5001 rejected'
);

-- A valid session, activated so chk_activated holds for the sync_delay test.
insert into public.sessions
  (id, user_id, exercise_revision_id, target_position_revision_id,
   fretting_hand_snapshot, accuracy_metric_version, calibration_method,
   declared_interval_ms)
values ('aaaaaaaa-0000-4000-8000-000000000200',
        'aaaaaaaa-0000-4000-8000-00000000000a',
        'aaaaaaaa-0000-4000-8000-000000000004',
        'aaaaaaaa-0000-4000-8000-000000000005',
        'left', 1, 'manual_4pt', 3000);

update public.sessions
   set lifecycle = 'active', activated_at = now()
 where id = 'aaaaaaaa-0000-4000-8000-000000000200';

-- ============================================================
-- chk_sync_delay_nonneg                               [1 assertion]
-- ============================================================
select throws_ok(
  $$update public.sessions set sync_delay_ms = -1
     where id = 'aaaaaaaa-0000-4000-8000-000000000200'$$,
  '23514', null,
  'sessions: negative sync_delay_ms rejected'
);

-- ============================================================
-- session_samples: uq_session_seq + chk_valid_reason   [5 assertions]
-- ============================================================
insert into public.session_samples
  (id, session_id, seq, is_valid, invalid_reason,
   placement_accuracy, confidence, interval_end_offset_ms)
values ('aaaaaaaa-0000-4000-8000-000000000300',
        'aaaaaaaa-0000-4000-8000-000000000200',
        0, true, null, 0.85, 0.90, 3000);

select throws_ok(
  $$insert into public.session_samples
      (id, session_id, seq, is_valid, invalid_reason,
       placement_accuracy, confidence, interval_end_offset_ms)
    values ('aaaaaaaa-0000-4000-8000-000000000301',
            'aaaaaaaa-0000-4000-8000-000000000200',
            0, true, null, 0.5, 0.5, 6000)$$,
  '23505', null,
  'session_samples: duplicate (session_id, seq) rejected by uq_session_seq'
);

select throws_ok(
  $$insert into public.session_samples
      (id, session_id, seq, is_valid, invalid_reason,
       placement_accuracy, confidence, interval_end_offset_ms)
    values ('aaaaaaaa-0000-4000-8000-000000000302',
            'aaaaaaaa-0000-4000-8000-000000000200',
            1, true, 'low_confidence', 0.5, 0.5, 6000)$$,
  '23514', null,
  'session_samples: valid sample with an invalid_reason rejected'
);

select throws_ok(
  $$insert into public.session_samples
      (id, session_id, seq, is_valid, invalid_reason,
       placement_accuracy, confidence, interval_end_offset_ms)
    values ('aaaaaaaa-0000-4000-8000-000000000303',
            'aaaaaaaa-0000-4000-8000-000000000200',
            1, true, null, null, 0.5, 6000)$$,
  '23514', null,
  'session_samples: valid sample with NULL placement_accuracy rejected'
);

select throws_ok(
  $$insert into public.session_samples
      (id, session_id, seq, is_valid, invalid_reason,
       placement_accuracy, confidence, interval_end_offset_ms)
    values ('aaaaaaaa-0000-4000-8000-000000000304',
            'aaaaaaaa-0000-4000-8000-000000000200',
            1, false, null, null, null, 6000)$$,
  '23514', null,
  'session_samples: invalid sample with NULL invalid_reason rejected'
);

select throws_ok(
  $$insert into public.session_samples
      (id, session_id, seq, is_valid, invalid_reason,
       placement_accuracy, confidence, interval_end_offset_ms)
    values ('aaaaaaaa-0000-4000-8000-000000000305',
            'aaaaaaaa-0000-4000-8000-000000000200',
            1, false, 'occlusion', 0.7, null, 6000)$$,
  '23514', null,
  'session_samples: invalid sample with non-null placement_accuracy rejected'
);

-- ============================================================
-- chk_accuracy_nullity (NULL-safe, errata form)        [4 assertions]
--
-- The metrics row requires a COMPLETED session (trg_metrics_only_completed).
-- Complete the session first, then assert the CHECK. The CHECK is evaluated
-- before the trigger, so the four cases below fail on 23514 either way; the
-- completed session removes any ambiguity about WHICH constraint fired.
-- ============================================================
update public.sessions
   set lifecycle = 'completed',
       active_duration_ms = 12000,
       ended_at_client = now(),
       completion_received_at = now(),
       scoring_status = 'insufficient_coverage'
 where id = 'aaaaaaaa-0000-4000-8000-000000000200';

-- Zero valid samples => accuracy and confidence MUST be NULL.
select throws_ok(
  $$insert into public.session_metrics
      (session_id, placement_accuracy, confidence_mean, valid_sample_ratio,
       coverage_duration_ms, expected_sample_count, submitted_sample_count,
       valid_sample_count)
    values ('aaaaaaaa-0000-4000-8000-000000000200',
            0.85, null, 0, 0, 4, 1, 0)$$,
  '23514', null,
  'metrics: valid_sample_count = 0 with non-null placement_accuracy rejected'
);

select throws_ok(
  $$insert into public.session_metrics
      (session_id, placement_accuracy, confidence_mean, valid_sample_ratio,
       coverage_duration_ms, expected_sample_count, submitted_sample_count,
       valid_sample_count)
    values ('aaaaaaaa-0000-4000-8000-000000000200',
            null, 0.90, 0, 0, 4, 1, 0)$$,
  '23514', null,
  'metrics: valid_sample_count = 0 with non-null confidence_mean rejected'
);

-- Positive valid samples => accuracy and confidence MUST be non-null.
-- This is the NULL-safe branch the errata added: a NULL-evaluating BETWEEN
-- would have PASSED the CHECK. It must now be rejected.
select throws_ok(
  $$insert into public.session_metrics
      (session_id, placement_accuracy, confidence_mean, valid_sample_ratio,
       coverage_duration_ms, expected_sample_count, submitted_sample_count,
       valid_sample_count)
    values ('aaaaaaaa-0000-4000-8000-000000000200',
            null, 0.90, 0.25, 3000, 4, 1, 1)$$,
  '23514', null,
  'metrics: valid_sample_count > 0 with NULL placement_accuracy rejected'
);

select throws_ok(
  $$insert into public.session_metrics
      (session_id, placement_accuracy, confidence_mean, valid_sample_ratio,
       coverage_duration_ms, expected_sample_count, submitted_sample_count,
       valid_sample_count)
    values ('aaaaaaaa-0000-4000-8000-000000000200',
            0.85, null, 0.25, 3000, 4, 1, 1)$$,
  '23514', null,
  'metrics: valid_sample_count > 0 with NULL confidence_mean rejected'
);

-- ============================================================
-- chk_state_response (idempotency, both-branch errata)  [4 assertions]
-- ============================================================

-- processing => response fields MUST be NULL.
select throws_ok(
  $$insert into public.idempotency_records
      (user_id, operation, idempotency_key, request_hash, state,
       response_status, response_body, expires_at)
    values ('aaaaaaaa-0000-4000-8000-00000000000a',
            'start_session', 't001-key-000001',
            repeat('a', 64), 'processing',
            200, null, now() + interval '1 day')$$,
  '23514', null,
  'idempotency: processing with non-null response_status rejected'
);

select throws_ok(
  $$insert into public.idempotency_records
      (user_id, operation, idempotency_key, request_hash, state,
       response_status, response_body, expires_at)
    values ('aaaaaaaa-0000-4000-8000-00000000000a',
            'start_session', 't001-key-000002',
            repeat('a', 64), 'processing',
            null, '{"ok":true}'::jsonb, now() + interval '1 day')$$,
  '23514', null,
  'idempotency: processing with non-null response_body rejected'
);

-- completed => response fields MUST be non-null.
select throws_ok(
  $$insert into public.idempotency_records
      (user_id, operation, idempotency_key, request_hash, state,
       response_status, response_body, expires_at)
    values ('aaaaaaaa-0000-4000-8000-00000000000a',
            'start_session', 't001-key-000003',
            repeat('a', 64), 'completed',
            null, '{"ok":true}'::jsonb, now() + interval '1 day')$$,
  '23514', null,
  'idempotency: completed with NULL response_status rejected'
);

select throws_ok(
  $$insert into public.idempotency_records
      (user_id, operation, idempotency_key, request_hash, state,
       response_status, response_body, expires_at)
    values ('aaaaaaaa-0000-4000-8000-00000000000a',
            'start_session', 't001-key-000004',
            repeat('a', 64), 'completed',
            200, null, now() + interval '1 day')$$,
  '23514', null,
  'idempotency: completed with NULL response_body rejected'
);

select finish();

rollback;
