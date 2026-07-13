-- ============================================================
-- 0004 — Triggers & helper functions (hard invariants only)
-- Fresh-database migration. Applies after 0001–0003.
-- All function bodies run with SET search_path = '' so every
-- identifier is schema-qualified; enum literals are cast to their
-- public types and built-ins are pg_catalog-qualified.
-- No chk_no_born_published. No alphabetical-order dependency:
-- validate_publish sets published_at + enforces completeness;
-- block_published_er rejects only when OLD.published was already true,
-- so a false->true transition passes both regardless of fire order.
-- ============================================================

-- ============================================================
-- 1. New-session shape: born 'created' with NULL activation/
--    completion/duration/sync/scoring fields.
-- ============================================================
create function public.trg_session_born_created() returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.lifecycle <> 'created'::public.session_lifecycle then
    raise exception 'new session must start as created'
      using errcode = 'check_violation';
  end if;
  if new.activated_at is not null
     or new.active_duration_ms is not null
     or new.ended_at_client is not null
     or new.completion_received_at is not null
     or new.sync_delay_ms is not null
     or new.scoring_status is not null then
    raise exception 'new session must have NULL activation/completion/duration/scoring fields'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger session_born_created
  before insert on public.sessions
  for each row execute function public.trg_session_born_created();

-- ============================================================
-- 2. Lifecycle transitions: created->active, active->completed,
--    active->abandoned. Non-lifecycle-changing updates pass.
-- ============================================================
create function public.trg_session_transition() returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.lifecycle is distinct from old.lifecycle
     and not (
       (old.lifecycle = 'created'::public.session_lifecycle
          and new.lifecycle = 'active'::public.session_lifecycle) or
       (old.lifecycle = 'active'::public.session_lifecycle
          and new.lifecycle = 'completed'::public.session_lifecycle) or
       (old.lifecycle = 'active'::public.session_lifecycle
          and new.lifecycle = 'abandoned'::public.session_lifecycle)) then
    raise exception 'illegal transition % -> %', old.lifecycle, new.lifecycle
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger session_transition
  before update on public.sessions
  for each row execute function public.trg_session_transition();

-- ============================================================
-- 3. Terminal-session sample protection.
--    Explicit TG_OP branches; forbid session_id/seq mutation;
--    block all writes touching a terminal session.
-- ============================================================
create function public.trg_no_samples_after_terminal() returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  lc_old public.session_lifecycle;
  lc_new public.session_lifecycle;
begin
  if tg_op = 'INSERT' then
    select s.lifecycle into lc_new from public.sessions s where s.id = new.session_id;
    if lc_new in ('completed'::public.session_lifecycle,
                  'abandoned'::public.session_lifecycle) then
      raise exception 'cannot insert sample into terminal session'
        using errcode = 'check_violation';
    end if;
    return new;

  elsif tg_op = 'DELETE' then
    select s.lifecycle into lc_old from public.sessions s where s.id = old.session_id;
    if lc_old in ('completed'::public.session_lifecycle,
                  'abandoned'::public.session_lifecycle) then
      raise exception 'cannot delete sample from terminal session'
        using errcode = 'check_violation';
    end if;
    return old;

  else -- UPDATE
    if new.session_id is distinct from old.session_id
       or new.seq is distinct from old.seq then
      raise exception 'cannot change session_id or seq of a sample'
        using errcode = 'check_violation';
    end if;
    select s.lifecycle into lc_old from public.sessions s where s.id = old.session_id;
    select s.lifecycle into lc_new from public.sessions s where s.id = new.session_id;
    if lc_old in ('completed'::public.session_lifecycle,
                  'abandoned'::public.session_lifecycle)
       or lc_new in ('completed'::public.session_lifecycle,
                     'abandoned'::public.session_lifecycle) then
      raise exception 'cannot modify sample of terminal session'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
end $$;

create trigger no_samples_after_terminal
  before insert or update or delete on public.session_samples
  for each row execute function public.trg_no_samples_after_terminal();

-- ============================================================
-- 4. Metrics lifecycle invariants.
-- ============================================================

-- Metrics row may exist only for a completed session.
create function public.trg_metrics_only_completed() returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
     and new.session_id is distinct from old.session_id then
    raise exception 'cannot change session_id of session_metrics'
      using errcode = 'check_violation';
  end if;

  if not exists (
    select 1 from public.sessions s
    where s.id = new.session_id
      and s.lifecycle = 'completed'::public.session_lifecycle
  ) then
    raise exception 'metrics only for completed session'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger metrics_only_completed
  before insert or update on public.session_metrics
  for each row execute function public.trg_metrics_only_completed();

-- A completed session's metrics row cannot be deleted while the parent
-- session still exists. This is deferred so ON DELETE CASCADE from a
-- deleted session/user remains possible.
create function public.trg_protect_completed_metrics() returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if exists (
    select 1 from public.sessions s
    where s.id = old.session_id
      and s.lifecycle = 'completed'::public.session_lifecycle
  )
  and not exists (
    select 1 from public.session_metrics m
    where m.session_id = old.session_id
  ) then
    raise exception 'cannot delete metrics of a completed session'
      using errcode = 'check_violation';
  end if;
  return null;
end $$;

create constraint trigger protect_completed_metrics
  after delete on public.session_metrics
  deferrable initially deferred
  for each row execute function public.trg_protect_completed_metrics();

-- A completed session must have a metrics row at commit (deferred).
create function public.trg_completed_needs_metrics() returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.lifecycle = 'completed'::public.session_lifecycle
     and not exists (
       select 1 from public.session_metrics m where m.session_id = new.id
     ) then
    raise exception 'completed session % needs metrics row', new.id
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create constraint trigger completed_needs_metrics
  after update on public.sessions
  deferrable initially deferred
  for each row execute function public.trg_completed_needs_metrics();

-- ============================================================
-- 5. Invalid-reason count consistency (deferred, both tables).
--    sum(reason counts) = submitted - valid.
--    Cascade-delete of the parent metrics row => nothing to check.
-- ============================================================
create function public.assert_reason_counts_sum(p_session_id uuid) returns void
  language plpgsql
  set search_path = ''
as $$
declare
  reason_total int;
  submitted    int;
  valid        int;
begin
  -- Metrics row gone (session/metrics cascade-deleted): no invariant to hold.
  if not exists (
    select 1
    from public.session_metrics m
    where m.session_id = p_session_id
  ) then
    return;
  end if;

  select coalesce(pg_catalog.sum(c.count), 0)
    into reason_total
    from public.session_invalid_reason_counts c
    where c.session_id = p_session_id;

  select m.submitted_sample_count, m.valid_sample_count
    into submitted, valid
    from public.session_metrics m
    where m.session_id = p_session_id;

  if reason_total <> (submitted - valid) then
    raise exception 'reason counts % <> submitted-valid % for session %',
      reason_total, submitted - valid, p_session_id
      using errcode = 'check_violation';
  end if;
end $$;

create function public.trg_reason_counts_sum() returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform public.assert_reason_counts_sum(new.session_id);
  elsif tg_op = 'DELETE' then
    perform public.assert_reason_counts_sum(old.session_id);
  else
    perform public.assert_reason_counts_sum(old.session_id);
    if new.session_id is distinct from old.session_id then
      perform public.assert_reason_counts_sum(new.session_id);
    end if;
  end if;
  return null;
end $$;

create constraint trigger reason_counts_sum_metrics
  after insert or update on public.session_metrics
  deferrable initially deferred
  for each row execute function public.trg_reason_counts_sum();

create constraint trigger reason_counts_sum_counts
  after insert or update or delete on public.session_invalid_reason_counts
  deferrable initially deferred
  for each row execute function public.trg_reason_counts_sum();

-- ============================================================
-- 6. Published-revision immutability.
-- ============================================================

create function public.er_is_published(er_id uuid) returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(
    (select er.published from public.exercise_revisions er where er.id = er_id),
    false);
$$;

create function public.tsa_parent_published(tpr_id uuid) returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(
    (select er.published
       from public.target_position_revisions tpr
       join public.exercise_revisions er on er.id = tpr.exercise_revision_id
      where tpr.id = tpr_id),
    false);
$$;

-- Published exercise_revisions rows are immutable (no UPDATE, no DELETE).
-- Rejects only when OLD.published is already true => false->true UPDATE passes.
create function public.trg_block_published_er() returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.published then
      raise exception 'delete of published revision %', old.id
        using errcode = 'check_violation';
    end if;
    return old;
  else
    if old.published then
      raise exception 'published revision % immutable', old.id
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
end $$;

create trigger block_published_er
  before update or delete on public.exercise_revisions
  for each row execute function public.trg_block_published_er();

-- target_position_revisions frozen under a published parent (OLD+NEW on UPDATE).
create function public.trg_freeze_tpr() returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if public.er_is_published(new.exercise_revision_id) then
      raise exception 'add target under published revision'
        using errcode = 'check_violation';
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    if public.er_is_published(old.exercise_revision_id) then
      raise exception 'delete target under published revision'
        using errcode = 'check_violation';
    end if;
    return old;
  else
    if public.er_is_published(old.exercise_revision_id)
       or public.er_is_published(new.exercise_revision_id) then
      raise exception 'target frozen (old or new parent published)'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
end $$;

create trigger freeze_tpr
  before insert or update or delete on public.target_position_revisions
  for each row execute function public.trg_freeze_tpr();

-- target_string_actions frozen under a published grandparent (OLD+NEW on UPDATE).
create function public.trg_freeze_tsa() returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if public.tsa_parent_published(new.target_position_revision_id) then
      raise exception 'add action under published revision'
        using errcode = 'check_violation';
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    if public.tsa_parent_published(old.target_position_revision_id) then
      raise exception 'delete action under published revision'
        using errcode = 'check_violation';
    end if;
    return old;
  else
    if public.tsa_parent_published(old.target_position_revision_id)
       or public.tsa_parent_published(new.target_position_revision_id) then
      raise exception 'action frozen (old or new parent published)'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
end $$;

create trigger freeze_tsa
  before insert or update or delete on public.target_string_actions
  for each row execute function public.trg_freeze_tsa();

-- ============================================================
-- 7. Publish-time validation (INSERT or UPDATE).
--    Snapshot must match the current exercise instrument; instrument
--    six-string; >=1 target; each target has exactly six string rows.
--    uq_tsa_string (schema) guarantees the six rows are strings 1–6.
-- ============================================================
create function public.trg_validate_publish() returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  bad      int;
  scount   int;
  ex_instr uuid;
begin
  if new.published then
    if pg_catalog.length(pg_catalog.btrim(new.title_snapshot)) = 0
       or pg_catalog.length(pg_catalog.btrim(new.instructions)) = 0 then
      raise exception 'cannot publish revision %: title/instructions required', new.id
        using errcode = 'check_violation';
    end if;

    select e.instrument_id, i.string_count
      into ex_instr, scount
      from public.exercises e
      join public.instruments i on i.id = e.instrument_id
     where e.id = new.exercise_id;

    if new.instrument_id_snapshot <> ex_instr then
      raise exception 'cannot publish revision %: instrument snapshot mismatch', new.id
        using errcode = 'check_violation';
    end if;

    if scount <> 6 then
      raise exception 'cannot publish revision %: instrument is not six-string', new.id
        using errcode = 'check_violation';
    end if;

    if not exists (
      select 1 from public.target_position_revisions tpr
      where tpr.exercise_revision_id = new.id
    ) then
      raise exception 'cannot publish revision %: no target', new.id
        using errcode = 'check_violation';
    end if;

    select count(*) into bad
      from public.target_position_revisions tpr
     where tpr.exercise_revision_id = new.id
       and (
         select count(*) from public.target_string_actions t
         where t.target_position_revision_id = tpr.id
       ) <> 6;

    if bad > 0 then
      raise exception 'cannot publish revision %: a target lacks six string rows', new.id
        using errcode = 'check_violation';
    end if;

    if new.published_at is null then
      new.published_at := pg_catalog.now();
    end if;
  end if;

  return new;
end $$;

create trigger validate_publish
  before insert or update on public.exercise_revisions
  for each row execute function public.trg_validate_publish();