-- ============================================================
-- 002 — Catalog publication + published-subtree immutability
-- Phase 1. Exercises trg_validate_publish, trg_block_published_er,
-- trg_freeze_tpr, trg_freeze_tsa (migration 0004).
-- All fixtures rolled back; the 0007 seed is never mutated.
-- Plan = 22 assertions.
-- ============================================================
begin;

create extension if not exists pgtap with schema extensions;

select plan(22);

-- ------------------------------------------------------------
-- Fixtures. Two instruments so the snapshot-mismatch case is reachable.
-- ------------------------------------------------------------
insert into public.instruments (id, name, string_count) values
  ('bbbbbbbb-0000-4000-8000-000000000001', 'T002 Guitar A', 6),
  ('bbbbbbbb-0000-4000-8000-000000000002', 'T002 Guitar B', 6);

insert into public.lessons (id, title, sort_order)
values ('bbbbbbbb-0000-4000-8000-000000000003', 'T002 Lesson', 0);

insert into public.exercises (id, lesson_id, instrument_id, title)
values ('bbbbbbbb-0000-4000-8000-000000000004',
        'bbbbbbbb-0000-4000-8000-000000000003',
        'bbbbbbbb-0000-4000-8000-000000000001',
        'T002 Exercise');

create or replace function pg_temp.t002_six_rows(p_tpr uuid) returns void
  language plpgsql as $$
begin
  insert into public.target_string_actions
    (target_position_revision_id, string_no, action, fret_no, finger_no)
  values
    (p_tpr, 1, 'open',    null, null),
    (p_tpr, 2, 'open',    null, null),
    (p_tpr, 3, 'open',    null, null),
    (p_tpr, 4, 'fretted',    2,    3),
    (p_tpr, 5, 'fretted',    2,    2),
    (p_tpr, 6, 'open',    null, null);
end $$;

-- ============================================================
-- Publish-time validation failures                    [5 assertions]
-- ============================================================

-- Empty title_snapshot.
insert into public.exercise_revisions
  (id, exercise_id, revision_no, title_snapshot, instructions,
   instrument_id_snapshot, published, published_at)
values ('bbbbbbbb-0000-4000-8000-000000000010',
        'bbbbbbbb-0000-4000-8000-000000000004', 1,
        '', 'Instructions present.',
        'bbbbbbbb-0000-4000-8000-000000000001', false, null);
insert into public.target_position_revisions (id, exercise_revision_id)
values ('bbbbbbbb-0000-4000-8000-000000000011',
        'bbbbbbbb-0000-4000-8000-000000000010');
select pg_temp.t002_six_rows('bbbbbbbb-0000-4000-8000-000000000011');

select throws_ok(
  $$update public.exercise_revisions set published = true
     where id = 'bbbbbbbb-0000-4000-8000-000000000010'$$,
  '23514', null,
  'publish: empty title_snapshot rejected'
);

-- Whitespace-only instructions.
insert into public.exercise_revisions
  (id, exercise_id, revision_no, title_snapshot, instructions,
   instrument_id_snapshot, published, published_at)
values ('bbbbbbbb-0000-4000-8000-000000000020',
        'bbbbbbbb-0000-4000-8000-000000000004', 2,
        'Title present', '   ',
        'bbbbbbbb-0000-4000-8000-000000000001', false, null);
insert into public.target_position_revisions (id, exercise_revision_id)
values ('bbbbbbbb-0000-4000-8000-000000000021',
        'bbbbbbbb-0000-4000-8000-000000000020');
select pg_temp.t002_six_rows('bbbbbbbb-0000-4000-8000-000000000021');

select throws_ok(
  $$update public.exercise_revisions set published = true
     where id = 'bbbbbbbb-0000-4000-8000-000000000020'$$,
  '23514', null,
  'publish: whitespace-only instructions rejected'
);

-- No target at all.
insert into public.exercise_revisions
  (id, exercise_id, revision_no, title_snapshot, instructions,
   instrument_id_snapshot, published, published_at)
values ('bbbbbbbb-0000-4000-8000-000000000030',
        'bbbbbbbb-0000-4000-8000-000000000004', 3,
        'Title', 'Instructions',
        'bbbbbbbb-0000-4000-8000-000000000001', false, null);

select throws_ok(
  $$update public.exercise_revisions set published = true
     where id = 'bbbbbbbb-0000-4000-8000-000000000030'$$,
  '23514', null,
  'publish: revision with no target rejected'
);

-- Target with only five string rows.
insert into public.exercise_revisions
  (id, exercise_id, revision_no, title_snapshot, instructions,
   instrument_id_snapshot, published, published_at)
values ('bbbbbbbb-0000-4000-8000-000000000040',
        'bbbbbbbb-0000-4000-8000-000000000004', 4,
        'Title', 'Instructions',
        'bbbbbbbb-0000-4000-8000-000000000001', false, null);
insert into public.target_position_revisions (id, exercise_revision_id)
values ('bbbbbbbb-0000-4000-8000-000000000041',
        'bbbbbbbb-0000-4000-8000-000000000040');
insert into public.target_string_actions
  (target_position_revision_id, string_no, action, fret_no, finger_no)
values
  ('bbbbbbbb-0000-4000-8000-000000000041', 1, 'open', null, null),
  ('bbbbbbbb-0000-4000-8000-000000000041', 2, 'open', null, null),
  ('bbbbbbbb-0000-4000-8000-000000000041', 3, 'open', null, null),
  ('bbbbbbbb-0000-4000-8000-000000000041', 4, 'open', null, null),
  ('bbbbbbbb-0000-4000-8000-000000000041', 5, 'open', null, null);

select throws_ok(
  $$update public.exercise_revisions set published = true
     where id = 'bbbbbbbb-0000-4000-8000-000000000040'$$,
  '23514', null,
  'publish: target with five string rows rejected'
);

-- Instrument snapshot mismatch (snapshot = B, exercise = A).
insert into public.exercise_revisions
  (id, exercise_id, revision_no, title_snapshot, instructions,
   instrument_id_snapshot, published, published_at)
values ('bbbbbbbb-0000-4000-8000-000000000050',
        'bbbbbbbb-0000-4000-8000-000000000004', 5,
        'Title', 'Instructions',
        'bbbbbbbb-0000-4000-8000-000000000002', false, null);
insert into public.target_position_revisions (id, exercise_revision_id)
values ('bbbbbbbb-0000-4000-8000-000000000051',
        'bbbbbbbb-0000-4000-8000-000000000050');
select pg_temp.t002_six_rows('bbbbbbbb-0000-4000-8000-000000000051');

select throws_ok(
  $$update public.exercise_revisions set published = true
     where id = 'bbbbbbbb-0000-4000-8000-000000000050'$$,
  '23514', null,
  'publish: instrument_id_snapshot mismatch rejected'
);

-- ============================================================
-- Successful publication                              [2 assertions]
-- ============================================================
insert into public.exercise_revisions
  (id, exercise_id, revision_no, title_snapshot, instructions,
   instrument_id_snapshot, published, published_at)
values ('bbbbbbbb-0000-4000-8000-000000000060',
        'bbbbbbbb-0000-4000-8000-000000000004', 6,
        'Complete Draft', 'Complete instructions.',
        'bbbbbbbb-0000-4000-8000-000000000001', false, null);
insert into public.target_position_revisions (id, exercise_revision_id)
values ('bbbbbbbb-0000-4000-8000-000000000061',
        'bbbbbbbb-0000-4000-8000-000000000060');
select pg_temp.t002_six_rows('bbbbbbbb-0000-4000-8000-000000000061');

select lives_ok(
  $$update public.exercise_revisions set published = true
     where id = 'bbbbbbbb-0000-4000-8000-000000000060'$$,
  'publish: complete draft revision publishes successfully'
);

select isnt(
  (select published_at from public.exercise_revisions
    where id = 'bbbbbbbb-0000-4000-8000-000000000060'),
  null,
  'publish: validate_publish assigned published_at'
);

-- ============================================================
-- Published exercise_revisions immutability           [3 assertions]
-- ============================================================
select throws_ok(
  $$update public.exercise_revisions set title_snapshot = 'Changed'
     where id = 'bbbbbbbb-0000-4000-8000-000000000060'$$,
  '23514', null,
  'immutability: UPDATE of a published revision rejected'
);

select throws_ok(
  $$update public.exercise_revisions set published = false
     where id = 'bbbbbbbb-0000-4000-8000-000000000060'$$,
  '23514', null,
  'immutability: un-publishing a published revision rejected'
);

select throws_ok(
  $$delete from public.exercise_revisions
     where id = 'bbbbbbbb-0000-4000-8000-000000000060'$$,
  '23514', null,
  'immutability: DELETE of a published revision rejected'
);

-- ============================================================
-- freeze_tpr                                          [5 assertions]
-- ============================================================
select throws_ok(
  $$insert into public.target_position_revisions (id, exercise_revision_id)
    values ('bbbbbbbb-0000-4000-8000-000000000062',
            'bbbbbbbb-0000-4000-8000-000000000060')$$,
  '23514', null,
  'freeze_tpr: INSERT under a published revision rejected'
);

select throws_ok(
  $$update public.target_position_revisions set created_at = now()
     where id = 'bbbbbbbb-0000-4000-8000-000000000061'$$,
  '23514', null,
  'freeze_tpr: UPDATE under a published revision rejected'
);

select throws_ok(
  $$update public.target_position_revisions
       set exercise_revision_id = 'bbbbbbbb-0000-4000-8000-000000000030'
     where id = 'bbbbbbbb-0000-4000-8000-000000000061'$$,
  '23514', null,
  'freeze_tpr: moving a target OUT of a published parent rejected (OLD side)'
);

select throws_ok(
  $$update public.target_position_revisions
       set exercise_revision_id = 'bbbbbbbb-0000-4000-8000-000000000060'
     where id = 'bbbbbbbb-0000-4000-8000-000000000021'$$,
  '23514', null,
  'freeze_tpr: moving a target INTO a published parent rejected (NEW side)'
);

select throws_ok(
  $$delete from public.target_position_revisions
     where id = 'bbbbbbbb-0000-4000-8000-000000000061'$$,
  '23514', null,
  'freeze_tpr: DELETE under a published revision rejected'
);

-- ============================================================
-- freeze_tsa                                          [5 assertions]
--
-- freeze_tsa is a BEFORE INSERT trigger. BEFORE-row triggers run to
-- completion before the unique index is consulted, so the freeze check
-- raises 23514 and uq_tsa_string is never reached. The INSERT below
-- targets an existing string_no ONLY because string_no is constrained to
-- 1-6 and all six already exist; the assertion is nonetheless a genuine
-- freeze_tsa test, not a unique-violation test.
-- ============================================================
select throws_ok(
  $$insert into public.target_string_actions
      (target_position_revision_id, string_no, action, fret_no, finger_no)
    values ('bbbbbbbb-0000-4000-8000-000000000061', 6, 'muted', null, null)$$,
  '23514', null,
  'freeze_tsa: INSERT under a published grandparent rejected by the BEFORE trigger'
);

select throws_ok(
  $$update public.target_string_actions set action = 'muted'
     where target_position_revision_id = 'bbbbbbbb-0000-4000-8000-000000000061'
       and string_no = 1$$,
  '23514', null,
  'freeze_tsa: UPDATE under a published grandparent rejected'
);

select throws_ok(
  $$update public.target_string_actions
       set target_position_revision_id = 'bbbbbbbb-0000-4000-8000-000000000021'
     where target_position_revision_id = 'bbbbbbbb-0000-4000-8000-000000000061'
       and string_no = 1$$,
  '23514', null,
  'freeze_tsa: moving an action OUT of a published subtree rejected (OLD side)'
);

select throws_ok(
  $$update public.target_string_actions
       set target_position_revision_id = 'bbbbbbbb-0000-4000-8000-000000000061'
     where target_position_revision_id = 'bbbbbbbb-0000-4000-8000-000000000041'
       and string_no = 1$$,
  '23514', null,
  'freeze_tsa: moving an action INTO a published subtree rejected (NEW side)'
);

select throws_ok(
  $$delete from public.target_string_actions
     where target_position_revision_id = 'bbbbbbbb-0000-4000-8000-000000000061'
       and string_no = 1$$,
  '23514', null,
  'freeze_tsa: DELETE under a published grandparent rejected'
);

-- ============================================================
-- Seeded catalog remains readable and intact          [2 assertions]
-- ============================================================
select is(
  (select published from public.exercise_revisions
    where id = '44444444-4444-4444-8444-000000000001'),
  true,
  'seed: 0007 revision is published'
);

select is(
  (select count(*)::int from public.target_string_actions
    where target_position_revision_id = '55555555-5555-4555-8555-000000000001'),
  6,
  'seed: 0007 target carries exactly six string rows'
);

select finish();

rollback;
