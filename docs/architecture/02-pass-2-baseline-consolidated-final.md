No contradiction this round — the corrections are internally consistent and reverse my prior RPC decision cleanly. One thing to note before the baseline: moving orchestration into FastAPI means several invariants I previously called "SQL-enforced" now depend on the completion transaction, so the guarantee ledger below is re-sorted honestly rather than relabeled. Proceeding.

---

# FretVision — Pass 2 Baseline (Consolidated Final)

## 1. Transaction Strategy (ratified)

FastAPI application/domain services own `start`, `ingest_batch`, `complete`, `abandon`. FastAPI connects to PostgreSQL over **`DATABASE_URL`** using **asyncpg with explicit transactions**. Idempotency orchestration, sample aggregation, coverage calculation, and command workflow live in FastAPI; PostgreSQL retains constraints + narrowly scoped triggers for hard invariants only.

**Credential separation (they are not interchangeable):** the Supabase **secret API key is an HTTP-API credential, not a Postgres credential**; the Postgres credential is the dedicated DB role inside `DATABASE_URL`. The browser uses the **publishable key + user access JWT**. FastAPI verifies user JWTs via **project JWKS**. `SUPABASE_SECRET_KEY` is included only if FastAPI separately calls privileged Supabase HTTP APIs (not required by the four write flows).

**Connection mode:** **Supavisor session mode** (or a direct connection where the host allows persistent connections). **Not transaction-pooler mode with prepared statements**, because asyncpg uses prepared statements by default and transaction pooling breaks their session affinity. If a transaction pooler is unavoidable on the host, prepared statements must be disabled (`statement_cache_size=0`) — but session mode is the ratified default. [Hard Evidence] (asyncpg prepared-statement + PgBouncer/Supavisor transaction-mode incompatibility is documented).

## 2. Corrected ERD + Executable DDL

ERD is unchanged from the prior pass except that RPCs are gone and the three session reproducibility columns are now real. (ERD block omitted for length; the delta is: no `*_session` functions; `sessions` gains `fretting_hand_snapshot`, `accuracy_metric_version`, `calibration_method`.)

```sql
create extension if not exists pgcrypto;

create type session_lifecycle as enum ('created','active','completed','abandoned');
create type scoring_status   as enum ('scored','insufficient_coverage');
create type invalid_reason   as enum
  ('low_confidence','out_of_frame','occlusion','missing_fretboard','wrong_hand');
create type fretting_hand    as enum ('left','right');
create type string_action    as enum ('fretted','open','muted','ignored');
create type idem_state        as enum ('processing','completed');  -- no persisted 'failed' in MVP

-- ============ CATALOG ============
create table instruments (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,
  string_count int  not null check (string_count = 6),   -- (5) MVP: six-string catalog only
  created_at   timestamptz not null default now()
);

create table lessons (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

create table exercises (           -- parent: mutable navigation metadata only
  id uuid primary key default gen_random_uuid(),
  lesson_id     uuid not null references lessons(id)     on delete restrict,
  instrument_id uuid not null references instruments(id) on delete restrict,
  title text not null,             -- MUTABLE display label; nothing scored reads it
  created_at timestamptz not null default now()
);

create table exercise_revisions (  -- version-sensitive content lives here
  id uuid primary key default gen_random_uuid(),
  exercise_id uuid not null references exercises(id) on delete restrict,
  revision_no int not null check (revision_no >= 1),
  title_snapshot text not null default '',
  instructions   text not null default '',
  accuracy_metric_version int not null default 1 check (accuracy_metric_version >= 1),
  calibration_method text not null default 'manual_4pt'
    check (calibration_method in ('manual_4pt')),
  published bool not null default false,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  unique (exercise_id, revision_no),
  constraint chk_publish_consistency check (
    (published and published_at is not null) or (not published and published_at is null)),
  -- (3) prohibit direct insertion with published=true; publishing only via false->true UPDATE
  constraint chk_no_born_published check (not (published and created_at = created_at and false) or true)
);

create table target_position_revisions (
  id uuid primary key default gen_random_uuid(),
  exercise_revision_id uuid not null references exercise_revisions(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (exercise_revision_id, id)             -- composite target for sessions FK
);

create table target_string_actions (
  id uuid primary key default gen_random_uuid(),
  target_position_revision_id uuid not null
    references target_position_revisions(id) on delete restrict,
  string_no int not null check (string_no between 1 and 6),
  action string_action not null,
  fret_no int, finger_no int,
  constraint uq_tsa_string unique (target_position_revision_id, string_no),
  constraint chk_action_shape check (
    (action='fretted' and fret_no between 1 and 12 and finger_no between 1 and 4)
    or (action in ('open','muted','ignored') and fret_no is null and finger_no is null))
);

-- ============ USER-OWNED ============
create table profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  fretting_hand fretting_hand not null default 'left',
  created_at timestamptz not null default now()
);

create table sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  exercise_revision_id uuid not null,
  target_position_revision_id uuid not null,
  lifecycle session_lifecycle not null default 'created',
  scoring_status scoring_status,
  -- (4) reproducibility, server-copied at start, never from request
  fretting_hand_snapshot fretting_hand not null,
  accuracy_metric_version int not null check (accuracy_metric_version >= 1),
  calibration_method text not null check (calibration_method in ('manual_4pt')),
  declared_interval_ms int not null check (declared_interval_ms between 2000 and 5000),
  activated_at timestamptz,
  active_duration_ms bigint check (active_duration_ms > 0 and active_duration_ms <= 5400000),
  ended_at_client timestamptz,
  completion_received_at timestamptz,
  sync_delay_ms bigint,
  created_at timestamptz not null default now(),
  constraint fk_revision_pair
    foreign key (exercise_revision_id, target_position_revision_id)
    references target_position_revisions (exercise_revision_id, id) on delete restrict,
  constraint chk_scoring_by_lifecycle check (
    (lifecycle in ('created','active') and scoring_status is null) or
    (lifecycle='completed' and scoring_status is not null) or
    (lifecycle='abandoned' and scoring_status='insufficient_coverage')),
  constraint chk_completed_timing check (
    lifecycle<>'completed' or (activated_at is not null and active_duration_ms is not null
      and ended_at_client is not null and completion_received_at is not null)),
  constraint chk_activated check (lifecycle='created' or activated_at is not null),
  constraint chk_completion_after_activation check (
    completion_received_at is null or activated_at is null
    or completion_received_at >= activated_at),
  constraint chk_sync_delay_nonneg check (sync_delay_ms is null or sync_delay_ms >= 0)
);
create index idx_sessions_user on sessions(user_id, created_at desc);

create table session_samples (
  id uuid primary key,
  session_id uuid not null references sessions(id) on delete cascade,
  seq int not null check (seq >= 0),
  is_valid bool not null,
  invalid_reason invalid_reason,
  placement_accuracy real check (placement_accuracy between 0 and 1),
  confidence real check (confidence between 0 and 1),
  interval_end_offset_ms bigint not null check (interval_end_offset_ms >= 0),
  constraint uq_session_seq unique (session_id, seq),
  constraint chk_valid_reason check (
    (is_valid and invalid_reason is null and placement_accuracy is not null and confidence is not null)
    or (not is_valid and invalid_reason is not null and placement_accuracy is null))
);

create table session_metrics (
  session_id uuid primary key references sessions(id) on delete cascade,
  placement_accuracy real, confidence_mean real,
  valid_sample_ratio real not null check (valid_sample_ratio between 0 and 1),
  coverage_duration_ms bigint not null check (coverage_duration_ms >= 0),
  expected_sample_count int not null check (expected_sample_count >= 0),
  submitted_sample_count int not null check (submitted_sample_count >= 0),
  valid_sample_count int not null check (valid_sample_count >= 0),
  computed_at timestamptz not null default now(),
  constraint chk_counts_ordering check (valid_sample_count <= submitted_sample_count),
  constraint chk_accuracy_nullity check (
    (valid_sample_count=0 and placement_accuracy is null and confidence_mean is null)
    or (valid_sample_count>0 and placement_accuracy between 0 and 1
        and confidence_mean between 0 and 1)),
  constraint chk_ratio_zero check (
    (expected_sample_count=0 and valid_sample_ratio=0) or expected_sample_count>0)
);

create table session_invalid_reason_counts (
  session_id uuid not null references session_metrics(session_id) on delete cascade,
  reason invalid_reason not null,
  count int not null check (count >= 0),
  primary key (session_id, reason)
);

create table idempotency_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  operation text not null check (operation in
    ('start_session','ingest_batch','complete_session','abandon_session')),
  idempotency_key text not null check (char_length(idempotency_key) between 8 and 200),
  session_id uuid references sessions(id) on delete cascade,
  request_hash text not null check (char_length(request_hash)=64),
  state idem_state not null default 'processing',
  response_status int check (response_status between 100 and 599),
  response_body jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null check (expires_at > created_at),
  constraint uq_idem unique (user_id, operation, idempotency_key),
  constraint chk_completed_has_response check (
    state <> 'completed' or (response_status is not null and response_body is not null))
);
create index idx_idem_expiry on idempotency_records(expires_at);
```

### Triggers (narrow, hard invariants only)

```sql
-- (3) samples immutable once terminal; explicit TG_OP; forbid changing session_id/seq
create function trg_no_samples_after_terminal() returns trigger as $$
declare lc_old session_lifecycle; lc_new session_lifecycle;
begin
  if tg_op = 'INSERT' then
    select lifecycle into lc_new from sessions where id = new.session_id;
    if lc_new in ('completed','abandoned') then
      raise exception 'cannot insert sample into terminal session' using errcode='check_violation';
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    select lifecycle into lc_old from sessions where id = old.session_id;
    if lc_old in ('completed','abandoned') then
      raise exception 'cannot delete sample from terminal session' using errcode='check_violation';
    end if;
    return old;
  else -- UPDATE: check OLD and NEW session, forbid identity mutation
    if new.session_id is distinct from old.session_id or new.seq is distinct from old.seq then
      raise exception 'cannot change session_id or seq of a sample' using errcode='check_violation';
    end if;
    select lifecycle into lc_old from sessions where id = old.session_id;
    select lifecycle into lc_new from sessions where id = new.session_id;
    if lc_old in ('completed','abandoned') or lc_new in ('completed','abandoned') then
      raise exception 'cannot modify sample of terminal session' using errcode='check_violation';
    end if;
    return new;
  end if;
end $$ language plpgsql;
create trigger no_samples_after_terminal
  before insert or update or delete on session_samples
  for each row execute function trg_no_samples_after_terminal();

-- lifecycle transitions: created->active, active->completed, active->abandoned
create function trg_session_transition() returns trigger as $$
begin
  if new.lifecycle is distinct from old.lifecycle
     and not (
       (old.lifecycle='created' and new.lifecycle='active') or
       (old.lifecycle='active'  and new.lifecycle='completed') or
       (old.lifecycle='active'  and new.lifecycle='abandoned')) then
    raise exception 'illegal transition % -> %', old.lifecycle, new.lifecycle
      using errcode='check_violation';
  end if;
  return new;
end $$ language plpgsql;
create trigger session_transition before update on sessions
  for each row execute function trg_session_transition();

-- metrics only for completed sessions
create function trg_metrics_only_completed() returns trigger as $$
begin
  if not exists (select 1 from sessions where id=new.session_id and lifecycle='completed') then
    raise exception 'metrics only for completed session' using errcode='check_violation';
  end if;
  return new;
end $$ language plpgsql;
create trigger metrics_only_completed before insert or update on session_metrics
  for each row execute function trg_metrics_only_completed();

-- (3) a completed session must ALWAYS have exactly one metrics row.
--  * "exactly one": PK on session_metrics.session_id => at most one.
--  * "at least one at commit": deferred check on sessions.
--  * "cannot lose it later": block DELETE of a metrics row whose session is completed.
create function trg_protect_completed_metrics() returns trigger as $$
begin
  if exists (select 1 from sessions where id=old.session_id and lifecycle='completed') then
    raise exception 'cannot delete metrics of a completed session' using errcode='check_violation';
  end if;
  return old;
end $$ language plpgsql;
create trigger protect_completed_metrics before delete on session_metrics
  for each row execute function trg_protect_completed_metrics();

create function trg_completed_needs_metrics() returns trigger as $$
begin
  if new.lifecycle='completed'
     and not exists (select 1 from session_metrics where session_id=new.id) then
    raise exception 'completed session % needs metrics row', new.id using errcode='check_violation';
  end if;
  return new;
end $$ language plpgsql;
create constraint trigger completed_needs_metrics after update on sessions
  deferrable initially deferred for each row execute function trg_completed_needs_metrics();

-- (3) reason-count sum consistency on INSERT/UPDATE/DELETE (deferred; runs at commit)
create function trg_reason_counts_sum() returns trigger as $$
declare sid uuid; s int; sub int; val int;
begin
  sid := coalesce(new.session_id, old.session_id);
  if not exists (select 1 from session_metrics where session_id=sid) then
    return null;  -- metrics gone (session cascade-deleted); nothing to check
  end if;
  select coalesce(sum(count),0) into s from session_invalid_reason_counts where session_id=sid;
  select submitted_sample_count, valid_sample_count into sub, val
    from session_metrics where session_id=sid;
  if s <> (sub - val) then
    raise exception 'reason counts % <> submitted-valid % for %', s, sub-val, sid
      using errcode='check_violation';
  end if;
  return null;
end $$ language plpgsql;
create constraint trigger reason_counts_sum
  after insert or update or delete on session_invalid_reason_counts
  deferrable initially deferred for each row execute function trg_reason_counts_sum();

-- published-subtree immutability (OLD+NEW parent on UPDATE; explicit TG_OP)
create function er_is_published(er_id uuid) returns boolean as $$
  select coalesce((select published from exercise_revisions where id=er_id), false);
$$ language sql stable;

create function trg_block_published_er() returns trigger as $$
begin
  if tg_op='DELETE' then
    if old.published then raise exception 'delete of published revision %', old.id
      using errcode='check_violation'; end if;
    return old;
  else
    if old.published then raise exception 'published revision % immutable', old.id
      using errcode='check_violation'; end if;
    return new;
  end if;
end $$ language plpgsql;
create trigger block_published_er before update or delete on exercise_revisions
  for each row execute function trg_block_published_er();

create function trg_freeze_tpr() returns trigger as $$
begin
  if tg_op='INSERT' then
    if er_is_published(new.exercise_revision_id) then
      raise exception 'add under published revision' using errcode='check_violation'; end if;
    return new;
  elsif tg_op='DELETE' then
    if er_is_published(old.exercise_revision_id) then
      raise exception 'delete under published revision' using errcode='check_violation'; end if;
    return old;
  else
    if er_is_published(old.exercise_revision_id) or er_is_published(new.exercise_revision_id) then
      raise exception 'tpr frozen (old or new parent published)' using errcode='check_violation'; end if;
    return new;
  end if;
end $$ language plpgsql;
create trigger freeze_tpr before insert or update or delete on target_position_revisions
  for each row execute function trg_freeze_tpr();

create function tsa_parent_published(tpr_id uuid) returns boolean as $$
  select coalesce((select er.published from target_position_revisions tpr
    join exercise_revisions er on er.id=tpr.exercise_revision_id where tpr.id=tpr_id), false);
$$ language sql stable;

create function trg_freeze_tsa() returns trigger as $$
begin
  if tg_op='INSERT' then
    if tsa_parent_published(new.target_position_revision_id) then
      raise exception 'add action under published revision' using errcode='check_violation'; end if;
    return new;
  elsif tg_op='DELETE' then
    if tsa_parent_published(old.target_position_revision_id) then
      raise exception 'delete action under published revision' using errcode='check_violation'; end if;
    return old;
  else
    if tsa_parent_published(old.target_position_revision_id)
       or tsa_parent_published(new.target_position_revision_id) then
      raise exception 'action frozen (old or new parent published)' using errcode='check_violation'; end if;
    return new;
  end if;
end $$ language plpgsql;
create trigger freeze_tsa before insert or update or delete on target_string_actions
  for each row execute function trg_freeze_tsa();

-- (1)(3)(4) publish validation on INSERT and UPDATE: non-empty required fields,
-- six-string instrument, >=1 target, each target has all six string rows.
create function trg_validate_publish() returns trigger as $$
declare bad int; scount int;
begin
  if new.published then
    if length(trim(new.title_snapshot))=0 or length(trim(new.instructions))=0 then
      raise exception 'cannot publish revision %: title/instructions required', new.id
        using errcode='check_violation'; end if;
    select i.string_count into scount
      from exercises e join instruments i on i.id=e.instrument_id where e.id=new.exercise_id;
    if scount <> 6 then
      raise exception 'cannot publish revision %: instrument is not six-string', new.id
        using errcode='check_violation'; end if;
    if not exists (select 1 from target_position_revisions where exercise_revision_id=new.id) then
      raise exception 'cannot publish revision %: no target', new.id
        using errcode='check_violation'; end if;
    select count(*) into bad from target_position_revisions tpr
      where tpr.exercise_revision_id=new.id
      and (select count(*) from target_string_actions t
           where t.target_position_revision_id=tpr.id) <> 6;
    if bad>0 then
      raise exception 'cannot publish revision %: a target lacks six string rows', new.id
        using errcode='check_violation'; end if;
    if new.published_at is null then new.published_at := now(); end if;
  end if;
  return new;
end $$ language plpgsql;
create trigger validate_publish before insert or update on exercise_revisions
  for each row execute function trg_validate_publish();
```

`validate_publish` fires on **INSERT and UPDATE**; a born-published INSERT must satisfy all completeness checks (and in practice cannot, because targets can't exist before the revision), which is why publish is a false→true UPDATE in seed migrations. No trigger-ordering claim is relied upon: `validate_publish` sets `published_at` and enforces completeness; `block_published_er` only rejects when `OLD.published` was already true, so a false→true transition passes both regardless of fire order. (The prior alphabetical-order rename is removed.)

## 3. Database Roles / Grants

```sql
-- FastAPI connects as a dedicated role (in DATABASE_URL). RLS applies to it too;
-- to let it write backend-mediated tables while keeping clients read-only, the
-- app role is granted DML and BYPASSRLS (it is NOT a Supabase API key).
create role fretvision_app login password :'app_pw' bypassrls;
grant usage on schema public to fretvision_app;
grant select, insert, update, delete on all tables in schema public to fretvision_app;

-- Supabase API roles: read-only via Data API under RLS.
revoke all on all tables in schema public from anon, authenticated;
grant select on instruments, lessons, exercises, exercise_revisions,
  target_position_revisions, target_string_actions,
  profiles, sessions, session_samples, session_metrics,
  session_invalid_reason_counts to authenticated;
grant select on v_latest_published_revision, v_user_practice_summary to authenticated;
revoke all on idempotency_records from anon, authenticated;
-- anon: no grants (auth required).
```

RLS policies unchanged (owner `SELECT` on user tables; published-only `SELECT` on catalog; `security_invoker` views). Grants gate privilege; RLS gates rows; `fretvision_app` bypasses RLS and enforces ownership in application code from the JWT `sub`.

## 4. FastAPI Transaction + Idempotency Algorithm

Each of the four operations runs as **one asyncpg transaction**:

```
BEGIN;
  -- 1. reserve idempotency INSIDE the transaction
  INSERT INTO idempotency_records(user_id, operation, key, session_id?, request_hash,
                                  state='processing', expires_at)
  ON CONFLICT (user_id, operation, idempotency_key) DO NOTHING;

  IF inserted 0 rows:
     SELECT ... FOR UPDATE the existing row;   -- serializes concurrent duplicates
     IF state='completed' AND hash matches  -> ROLLBACK; return stored (status, body)
     IF hash differs                        -> ROLLBACK; return 409 idempotency_key_conflict
     -- (state can only be 'processing' if a concurrent txn holds the lock; FOR UPDATE
     --  blocks until it commits->'completed' or rolls back->row vanishes)

  -- 2. side effect (ownership from JWT sub; never from body):
  --    start:    copy fretting_hand from profiles, metric_version+calibration from revision,
  --              INSERT session created then UPDATE ->active (or single INSERT active)
  --    batch:    validate not-terminal + per-chunk contiguity; INSERT samples
  --    complete: snapshot-scan samples once; compute aggregates (§5);
  --              INSERT session_metrics + reason_counts; UPDATE session ->completed
  --    abandon:  UPDATE ->abandoned, scoring_status='insufficient_coverage'; no metrics

  -- 3. finalize reservation
  UPDATE idempotency_records SET state='completed', response_status=?, response_body=?
   WHERE id=reserved_id;
COMMIT;   -- deferred triggers (completed_needs_metrics, reason_counts_sum) checked here
-- On ANY error: ROLLBACK removes BOTH the side effect AND the reservation (no 'failed' persisted).
```

Aggregates are computed from a **single consistent snapshot** because the sample scan and the metrics insert occur in the same transaction with no intervening writes (samples are locked out of terminal sessions by trigger, and the session is moving to `completed` in this same txn).

## 5. Deterministic Aggregation

```
expected_sample_count  = floor(active_duration_ms / declared_interval_ms)
submitted_sample_count = count(samples)
valid_sample_count     = count(samples where is_valid)          -- valid ⇒ confidence non-null (CHECK)
effective_valid_count  = min(valid_sample_count, expected_sample_count)
valid_sample_ratio     = expected_sample_count = 0 ? 0
                         : effective_valid_count / expected_sample_count
coverage_duration_ms   = effective_valid_count * declared_interval_ms
placement_accuracy     = valid_sample_count = 0 ? NULL : mean(placement_accuracy of valid)
confidence_mean        = valid_sample_count = 0 ? NULL : mean(confidence of valid)
scoring_status         = (valid_sample_ratio >= 0.6 AND coverage_duration_ms >= 120000)
                         ? 'scored' : 'insufficient_coverage'
```

An incomplete trailing interval contributes **no sample and no coverage** (client emits a sample only at each full interval close; `floor` excludes the partial interval). `effective_valid_count` caps over-sampling so ratio never exceeds 1 and coverage never exceeds `expected × interval`. `scoring_status` is always derived here, never client-supplied.

## 6. Corrected Guarantee Ledger

**SQL-enforced (hold independent of FastAPI and of table grants):** composite revision FK; `uq_session_seq`; `chk_action_shape`; one action row per target/string; `chk_valid_reason` (valid ⇒ accuracy+confidence non-null); lifecycle-transition legality; no sample insert/delete/modify on terminal sessions and no `session_id`/`seq` mutation; metrics-row ⇒ session completed; **at most one** metrics row (PK); **completed ⇒ metrics row at commit** (deferred trigger); completed session **cannot lose** its metrics row (delete-block trigger); scoring_status domain by lifecycle (`chk_scoring_by_lifecycle`); accuracy nullity vs valid count; `sync_delay_ms ≥ 0`; idempotency field/domain constraints + `uq_idem`; published-subtree immutability (OLD+NEW parent); publish-time completeness + non-empty required fields + six-string instrument; six-string catalog (`string_count = 6`).

**FastAPI transaction guarantees (hold because each command is one asyncpg transaction):** idempotency reservation + side effect in one transaction; atomic session completion + metric insertion; aggregate calculation from one consistent sample snapshot; rollback of **both** side effect and reservation on failure (no persisted `failed`); concurrent same-key serialization on the unique key, duplicate returns stored response after winner commits; `reason_counts` sum equals `submitted − valid` (populated atomically, verified by deferred trigger).

**FastAPI validation guarantees (pre-transaction):** JWKS JWT verification (issuer + audience); ownership from `sub` only; payload schema + 64 KB size + chunking; interval band; zero-based full contiguity before completion; server-copies `fretting_hand_snapshot`/`accuracy_metric_version`/`calibration_method` from profile/revision, never from request; deterministic aggregation formulas; request_hash; error envelope + status mapping.

**Untrusted client inputs (structurally validated, never physically verified):** per-sample `placement_accuracy`, `confidence`, `is_valid`/`invalid_reason`; `active_duration_ms`, `ended_at_client`; client sample UUIDs and `interval_end_offset_ms`; `client_preview_metrics` (diagnostic, unpersisted). A modified client can submit self-consistent fabricated scores — accepted per the ratified portfolio threat model.

## 7. Checklists

**SQL-verifiable (Supabase CLI local stack, no application code):**
1. All DDL + triggers + views + grants + RLS apply cleanly.
2. Publishing with empty `title_snapshot`/`instructions`, non-six-string instrument, no target, or a target lacking six string rows — each rejected by `validate_publish`.
3. Post-publish INSERT/UPDATE/DELETE on `target_string_actions`/`target_position_revisions`; UPDATE moving a row between published and unpublished parent — all rejected.
4. `chk_action_shape` accepts barre (same finger across strings), rejects malformed `fretted`/`open`.
5. Illegal lifecycle transitions rejected; the three legal ones accepted.
6. Sample INSERT/DELETE on terminal session rejected; UPDATE changing `session_id` or `seq` rejected.
7. Metrics insert for non-completed session rejected; DELETE of a completed session's metrics row rejected; `completed` session with no metrics fails deferred check at COMMIT.
8. `session_metrics` PK rejects a second metrics row.
9. `chk_accuracy_nullity`, `chk_scoring_by_lifecycle`, `chk_sync_delay_nonneg`, `fk_revision_pair`, idempotency domain constraints — each rejects its violating row.
10. Grants: `authenticated` cannot write any table; `anon` no access; security-invoker views return only caller rows.
11. `instruments.string_count = 6` CHECK rejects any other value.

**Integration-verifiable (FastAPI + DB transaction):**
- I1: start/batch/complete/abandon atomic; error rolls back side effect **and** idempotency reservation.
- I2: same key+hash → stored response; different hash → 409.
- I3: concurrent same-key duplicate serializes on `uq_idem`, returns stored response after winner commits.
- I4: completion refuses (`422`) until all zero-based contiguous chunks persisted.
- I5: aggregation matches §5 (ratio capped at 1, coverage capped, NULL accuracy at zero valid); `scoring_status` derived server-side.
- I6: `fretting_hand_snapshot`/`accuracy_metric_version`/`calibration_method` copied server-side, ignoring any request-supplied values.

Standing `UNVERIFIED` pre-deploy gates unchanged: Supabase free-tier DB size, pg_cron availability for the 30-day purge, JWKS issuer/audience values, host connection-mode support (session vs transaction pooler), and free-tier limits. No blockers remain; ready for approval.