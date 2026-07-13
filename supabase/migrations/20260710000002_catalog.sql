-- ============================================================
-- 0002 — Catalog tables
-- Errata folded in:
--   * exercise_revisions.instrument_id_snapshot born NOT NULL + FK
--     (no add-column / backfill / set-not-null sequence).
--   * chk_no_born_published (tautology) NEVER created.
-- Publish is a false->true UPDATE only; born-published INSERT is
-- rejected by validate_publish (migration 0004), which cannot pass on
-- INSERT because targets/string-rows can't exist before the revision.
-- ============================================================

create table instruments (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,
  string_count int  not null check (string_count = 6),   -- MVP: six-string catalog only
  created_at   timestamptz not null default now()
);

create table lessons (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  sort_order int  not null default 0,
  created_at timestamptz not null default now()
);

create table exercises (                         -- parent: mutable navigation metadata only
  id            uuid primary key default gen_random_uuid(),
  lesson_id     uuid not null references lessons(id)     on delete restrict,
  instrument_id uuid not null references instruments(id) on delete restrict,
  title         text not null,                   -- MUTABLE display label; nothing scored reads it
  created_at    timestamptz not null default now()
);

create table exercise_revisions (                -- version-sensitive content lives here
  id                      uuid primary key default gen_random_uuid(),
  exercise_id             uuid not null references exercises(id) on delete restrict,
  revision_no             int  not null check (revision_no >= 1),
  title_snapshot          text not null default '',
  instructions            text not null default '',
  accuracy_metric_version int  not null default 1 check (accuracy_metric_version >= 1),
  calibration_method      text not null default 'manual_4pt'
                            check (calibration_method in ('manual_4pt')),
  -- Immutable historical instrument identity, present from creation.
  instrument_id_snapshot  uuid not null,
  published               bool not null default false,
  published_at            timestamptz,
  created_at              timestamptz not null default now(),
  unique (exercise_id, revision_no),
  constraint chk_publish_consistency check (
    (published and published_at is not null)
    or (not published and published_at is null)
  ),
  constraint fk_er_instrument
    foreign key (instrument_id_snapshot) references instruments(id) on delete restrict
);

create table target_position_revisions (
  id                   uuid primary key default gen_random_uuid(),
  exercise_revision_id uuid not null references exercise_revisions(id) on delete restrict,
  created_at           timestamptz not null default now(),
  unique (exercise_revision_id, id)              -- composite target for sessions FK
);

create table target_string_actions (
  id                          uuid primary key default gen_random_uuid(),
  target_position_revision_id uuid not null
                                references target_position_revisions(id) on delete restrict,
  string_no                   int not null check (string_no between 1 and 6),
  action                      string_action not null,
  fret_no                     int,
  finger_no                   int,
  constraint uq_tsa_string unique (target_position_revision_id, string_no),
  constraint chk_action_shape check (
    (
      action = 'fretted'
      and fret_no is not null
      and fret_no between 1 and 12
      and finger_no is not null
      and finger_no between 1 and 4
    )
    or
    (
      action in ('open', 'muted', 'ignored')
      and fret_no is null
      and finger_no is null
    )
  )
);