-- ============================================================
-- 0003 — User-owned tables
-- Errata folded in:
--   * session_metrics.chk_accuracy_nullity in NULL-safe form
--     (explicit IS NOT NULL + range in the valid_sample_count > 0 branch).
--   * idempotency_records.chk_state_response as the both-branch form
--     (chk_completed_has_response is NEVER created).
-- Table order: session_metrics precedes session_invalid_reason_counts,
-- which references it.
-- ============================================================

create table profiles (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  display_name  text,
  fretting_hand fretting_hand not null default 'left',
  created_at    timestamptz not null default now()
);

create table sessions (
  id                          uuid primary key default gen_random_uuid(),
  user_id                     uuid not null references auth.users(id) on delete cascade,
  exercise_revision_id        uuid not null,
  target_position_revision_id uuid not null,
  lifecycle                   session_lifecycle not null default 'created',
  scoring_status              scoring_status,
  -- reproducibility, server-copied at start, never from request
  fretting_hand_snapshot      fretting_hand not null,
  accuracy_metric_version     int not null check (accuracy_metric_version >= 1),
  calibration_method          text not null check (calibration_method in ('manual_4pt')),
  declared_interval_ms        int not null check (declared_interval_ms between 2000 and 5000),
  activated_at                timestamptz,
  active_duration_ms          bigint check (active_duration_ms > 0 and active_duration_ms <= 5400000),
  ended_at_client             timestamptz,
  completion_received_at      timestamptz,
  sync_delay_ms               bigint,
  created_at                  timestamptz not null default now(),
  constraint fk_revision_pair
    foreign key (exercise_revision_id, target_position_revision_id)
    references target_position_revisions (exercise_revision_id, id) on delete restrict,
  constraint chk_scoring_by_lifecycle check (
    (lifecycle in ('created', 'active') and scoring_status is null)
    or (lifecycle = 'completed' and scoring_status is not null)
    or (lifecycle = 'abandoned' and scoring_status = 'insufficient_coverage')
  ),
  constraint chk_completed_timing check (
    lifecycle <> 'completed'
    or (activated_at is not null and active_duration_ms is not null
        and ended_at_client is not null and completion_received_at is not null)
  ),
  constraint chk_activated check (lifecycle = 'created' or activated_at is not null),
  constraint chk_completion_after_activation check (
    completion_received_at is null or activated_at is null
    or completion_received_at >= activated_at
  ),
  constraint chk_sync_delay_nonneg check (sync_delay_ms is null or sync_delay_ms >= 0)
);
create index idx_sessions_user on sessions(user_id, created_at desc);

create table session_samples (
  id                     uuid primary key,
  session_id             uuid not null references sessions(id) on delete cascade,
  seq                    int  not null check (seq >= 0),
  is_valid               bool not null,
  invalid_reason         invalid_reason,
  placement_accuracy     real check (placement_accuracy between 0 and 1),
  confidence             real check (confidence between 0 and 1),
  interval_end_offset_ms bigint not null check (interval_end_offset_ms >= 0),
  constraint uq_session_seq unique (session_id, seq),
  constraint chk_valid_reason check (
    (is_valid and invalid_reason is null
       and placement_accuracy is not null and confidence is not null)
    or (not is_valid and invalid_reason is not null and placement_accuracy is null)
  )
);

create table session_metrics (
  session_id             uuid primary key references sessions(id) on delete cascade,
  placement_accuracy     real,
  confidence_mean        real,
  valid_sample_ratio     real   not null check (valid_sample_ratio between 0 and 1),
  coverage_duration_ms   bigint not null check (coverage_duration_ms >= 0),
  expected_sample_count  int    not null check (expected_sample_count >= 0),
  submitted_sample_count int    not null check (submitted_sample_count >= 0),
  valid_sample_count     int    not null check (valid_sample_count >= 0),
  computed_at            timestamptz not null default now(),
  constraint chk_counts_ordering check (valid_sample_count <= submitted_sample_count),
  -- NULL-safe accuracy nullity (errata): explicit non-null + range in the >0 branch.
  constraint chk_accuracy_nullity check (
    (valid_sample_count = 0
       and placement_accuracy is null
       and confidence_mean   is null)
    or
    (valid_sample_count > 0
       and placement_accuracy is not null and placement_accuracy >= 0 and placement_accuracy <= 1
       and confidence_mean   is not null and confidence_mean   >= 0 and confidence_mean   <= 1)
  ),
  constraint chk_ratio_zero check (
    (expected_sample_count = 0 and valid_sample_ratio = 0) or expected_sample_count > 0
  )
);

create table session_invalid_reason_counts (
  session_id uuid not null references session_metrics(session_id) on delete cascade,
  reason     invalid_reason not null,
  count      int not null check (count >= 0),
  primary key (session_id, reason)
);

create table idempotency_records (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  operation       text not null check (operation in
                    ('start_session', 'ingest_batch', 'complete_session', 'abandon_session')),
  idempotency_key text not null check (char_length(idempotency_key) between 8 and 200),
  session_id      uuid references sessions(id) on delete cascade,
  request_hash    text not null check (char_length(request_hash) = 64),
  state           idem_state not null default 'processing',
  response_status int check (response_status between 100 and 599),
  response_body   jsonb,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null check (expires_at > created_at),
  constraint uq_idem unique (user_id, operation, idempotency_key),
  -- Both-branch state/response coupling (errata): processing => NULL response,
  -- completed => non-null response. Replaces chk_completed_has_response.
  constraint chk_state_response check (
    (state = 'processing'
       and response_status is null
       and response_body   is null)
    or
    (state = 'completed'
       and response_status is not null
       and response_body   is not null)
  )
);
create index idx_idem_expiry on idempotency_records(expires_at);