-- ============================================================
-- 0007 — Catalog seed
-- Deterministic UUIDs => reset-safe and idempotent.
-- Authoring flow exercises the approved triggers:
--   1. Insert draft revision (published = false).
--   2. Insert target + exactly six string-action rows (freeze triggers
--      permit writes only while the parent revision is unpublished).
--   3. Publish via false -> true UPDATE, which runs validate_publish
--      (title/instructions non-empty, snapshot match, six-string
--      instrument, >=1 target, six rows per target) and sets
--      published_at; block_published_er passes because OLD.published
--      was false.
-- Original exercise content only. No copyrighted material.
-- ============================================================

-- ------------------------------------------------------------
-- Instrument
-- ------------------------------------------------------------
insert into public.instruments (id, name, string_count)
values ('11111111-1111-4111-8111-000000000001', 'Standard Six-String Guitar', 6)
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- Lesson
-- ------------------------------------------------------------
insert into public.lessons (id, title, sort_order)
values ('22222222-2222-4222-8222-000000000001', 'Open Chord Foundations', 0)
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- Exercise
-- ------------------------------------------------------------
insert into public.exercises (id, lesson_id, instrument_id, title)
values (
  '33333333-3333-4333-8333-000000000001',
  '22222222-2222-4222-8222-000000000001',
  '11111111-1111-4111-8111-000000000001',
  'E Minor Shape'
)
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- Draft revision (published = false)
-- ------------------------------------------------------------
insert into public.exercise_revisions (
  id,
  exercise_id,
  revision_no,
  title_snapshot,
  instructions,
  accuracy_metric_version,
  calibration_method,
  instrument_id_snapshot,
  published,
  published_at
)
values (
  '44444444-4444-4444-8444-000000000001',
  '33333333-3333-4333-8333-000000000001',
  1,
  'E Minor Shape',
  'Complete the four-point fretboard calibration, then hold the E minor shape: '
    || 'second fret of the fifth string with the middle finger, second fret of the '
    || 'fourth string with the ring finger. Let the remaining four strings ring open. '
    || 'Keep the guitar and camera still for the whole session.',
  1,
  'manual_4pt',
  '11111111-1111-4111-8111-000000000001',
  false,
  null
)
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- Target position (parent revision is still unpublished)
-- ------------------------------------------------------------
insert into public.target_position_revisions (id, exercise_revision_id)
values (
  '55555555-5555-4555-8555-000000000001',
  '44444444-4444-4444-8444-000000000001'
)
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- Exactly six string-action rows (strings 1..6).
-- String numbering: 1 = high E ... 6 = low E.
-- E minor: strings 4 and 5 fretted at fret 2; all others open.
-- ------------------------------------------------------------
insert into public.target_string_actions
  (id, target_position_revision_id, string_no, action, fret_no, finger_no)
values
  ('66666666-6666-4666-8666-000000000001',
   '55555555-5555-4555-8555-000000000001', 1, 'open',    null, null),
  ('66666666-6666-4666-8666-000000000002',
   '55555555-5555-4555-8555-000000000001', 2, 'open',    null, null),
  ('66666666-6666-4666-8666-000000000003',
   '55555555-5555-4555-8555-000000000001', 3, 'open',    null, null),
  ('66666666-6666-4666-8666-000000000004',
   '55555555-5555-4555-8555-000000000001', 4, 'fretted',    2,    3),
  ('66666666-6666-4666-8666-000000000005',
   '55555555-5555-4555-8555-000000000001', 5, 'fretted',    2,    2),
  ('66666666-6666-4666-8666-000000000006',
   '55555555-5555-4555-8555-000000000001', 6, 'open',    null, null)
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- Publish: false -> true UPDATE.
-- published_at is left NULL; validate_publish assigns now().
-- Guarded so a re-run against an already-published revision is a no-op
-- rather than an UPDATE that block_published_er would reject.
-- ------------------------------------------------------------
update public.exercise_revisions
   set published = true
 where id = '44444444-4444-4444-8444-000000000001'
   and not published;