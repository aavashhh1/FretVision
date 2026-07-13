# FretVision — Final Errata Patch
 
**Precedence:** This patch overrides conflicting parts of the Pass 2 Baseline — Consolidated Final.
 
**Important:** This document is a delta against an earlier schema draft. Fold every correction directly into clean fresh-database migrations. Do not ship the defective definitions and then repair them using sequential `DROP`/`ALTER` statements in a fresh installation.
 
One note on instrument identity: validating that `instrument_id_snapshot` matches `exercises.instrument_id` at publish time is a point-in-time check. The parent may change afterward; the immutable snapshot is the authoritative historical value used for reproduction.
 
```sql
-- ============================================================
-- 1. Remove tautological constraint
-- ============================================================
alter table exercise_revisions drop constraint chk_no_born_published;
 
-- ============================================================
-- 2. Replace chk_accuracy_nullity (NULL-safe; explicit non-null + range)
-- ============================================================
alter table session_metrics drop constraint chk_accuracy_nullity;
alter table session_metrics add constraint chk_accuracy_nullity check (
  (valid_sample_count = 0
     and placement_accuracy is null
     and confidence_mean   is null)
  or
  (valid_sample_count > 0
     and placement_accuracy is not null and placement_accuracy >= 0 and placement_accuracy <= 1
     and confidence_mean   is not null and confidence_mean   >= 0 and confidence_mean   <= 1)
);
-- PostgreSQL CHECK constraints pass when their expression is TRUE or NULL.
-- Explicit IS NOT NULL checks are required in the valid-count > 0 branch.
 
-- ============================================================
-- 3. Remove CREATE ROLE from migrations; least-privilege grants only
-- ============================================================
-- No CREATE ROLE statement or password belongs in version-controlled migrations.
-- `fretvision_app` is provisioned through a separate secure bootstrap/deployment step.
-- Its password exists only inside DATABASE_URL in the backend secret store.
 
-- Backend-mediated user/session tables: DML for the application role.
grant select, insert, update, delete on
  profiles, sessions, session_samples, session_metrics,
  session_invalid_reason_counts, idempotency_records
  to fretvision_app;
 
-- Catalog: read-only for the application role. Authoring remains migration/admin-only.
grant select on
  instruments, lessons, exercises, exercise_revisions,
  target_position_revisions, target_string_actions
  to fretvision_app;
 
grant select on v_latest_published_revision, v_user_practice_summary to fretvision_app;
grant usage on schema public to fretvision_app;
-- Any previous `GRANT ... ON ALL TABLES IN SCHEMA public` is superseded.
-- BYPASSRLS is assigned during secure bootstrap, not in the normal migrations.
 
-- ============================================================
-- 4. Session-start shape
-- New sessions begin as `created` with activation/completion/duration/scoring fields NULL.
-- FastAPI updates the session to `active` in the same transaction.
-- ============================================================
create function trg_session_born_created() returns trigger as $$
begin
  if new.lifecycle <> 'created' then
    raise exception 'new session must start as created' using errcode='check_violation';
  end if;
  if new.activated_at is not null
     or new.active_duration_ms is not null
     or new.ended_at_client is not null
     or new.completion_received_at is not null
     or new.sync_delay_ms is not null
     or new.scoring_status is not null then
    raise exception 'new session must have NULL activation/completion/duration/scoring fields'
      using errcode='check_violation';
  end if;
  return new;
end $$ language plpgsql;
 
create trigger session_born_created before insert on sessions
  for each row execute function trg_session_born_created();
 
-- ============================================================
-- 5. Preserve historical instrument identity on the revision
-- ============================================================
alter table exercise_revisions
  add column instrument_id_snapshot uuid;
 
-- Backfill existing draft rows before promoting the column to NOT NULL.
update exercise_revisions er
  set instrument_id_snapshot = e.instrument_id
  from exercises e
  where e.id = er.exercise_id
    and er.instrument_id_snapshot is null;
 
alter table exercise_revisions
  alter column instrument_id_snapshot set not null,
  add constraint fk_er_instrument
    foreign key (instrument_id_snapshot) references instruments(id) on delete restrict;
 
-- Publish-time validation: snapshot must match the exercise instrument at publication.
create or replace function trg_validate_publish() returns trigger as $$
declare
  bad int;
  scount int;
  ex_instr uuid;
begin
  if new.published then
    if length(trim(new.title_snapshot)) = 0 or length(trim(new.instructions)) = 0 then
      raise exception 'cannot publish revision %: title/instructions required', new.id
        using errcode='check_violation';
    end if;
 
    select e.instrument_id, i.string_count
      into ex_instr, scount
      from exercises e
      join instruments i on i.id = e.instrument_id
      where e.id = new.exercise_id;
 
    if new.instrument_id_snapshot <> ex_instr then
      raise exception 'cannot publish revision %: instrument snapshot mismatch', new.id
        using errcode='check_violation';
    end if;
 
    if scount <> 6 then
      raise exception 'cannot publish revision %: instrument is not six-string', new.id
        using errcode='check_violation';
    end if;
 
    if not exists (
      select 1
      from target_position_revisions
      where exercise_revision_id = new.id
    ) then
      raise exception 'cannot publish revision %: no target', new.id
        using errcode='check_violation';
    end if;
 
    select count(*)
      into bad
      from target_position_revisions tpr
      where tpr.exercise_revision_id = new.id
        and (
          select count(*)
          from target_string_actions t
          where t.target_position_revision_id = tpr.id
        ) <> 6;
 
    if bad > 0 then
      raise exception 'cannot publish revision %: a target lacks six string rows', new.id
        using errcode='check_violation';
    end if;
 
    if new.published_at is null then
      new.published_at := now();
    end if;
  end if;
 
  return new;
end $$ language plpgsql;
-- instrument_id_snapshot is frozen after publication by the published-revision trigger.
 
-- ============================================================
-- 6. Strengthen idempotency state/response coupling
-- ============================================================
alter table idempotency_records drop constraint chk_completed_has_response;
alter table idempotency_records add constraint chk_state_response check (
  (state = 'processing'
     and response_status is null
     and response_body is null)
  or
  (state = 'completed'
     and response_status is not null
     and response_body is not null)
);
```
 
## Affected guarantee-ledger replacements
 
- **SQL-enforced:** valid-count greater than zero explicitly requires non-null, in-range `placement_accuracy` and `confidence_mean`.
- **SQL-enforced:** a new session must be born `created` with activation, completion, duration, sync-delay, and scoring fields all null.
- **SQL-enforced:** `exercise_revisions.instrument_id_snapshot` is non-null, references `instruments`, must match the exercise instrument at publication, and is immutable after publication.
- **SQL-enforced:** `processing` idempotency rows have null response fields; `completed` rows have non-null response fields.
- **Grant strategy:** application DML is limited to backend-mediated user/session/idempotency tables; catalog access is read-only; role provisioning and passwords remain outside version control.
- **FastAPI transaction guarantee:** session start is `INSERT created → UPDATE active` with server-generated `activated_at` inside one transaction. The single-insert-active alternative is withdrawn.
## Clean-migration assembly rules
 
For a fresh database migration set:
 
- Do not create `chk_no_born_published`.
- Define the corrected NULL-safe `chk_accuracy_nullity` directly.
- Create `instrument_id_snapshot` as part of the initial revision table definition when possible.
- Define `chk_state_response` directly rather than creating and dropping an earlier constraint.
- Define `session_born_created` in the initial trigger migration.
- Keep secure role creation and passwords outside repository migrations.
- Apply application-role grants only after the securely provisioned role exists.
All errata items are approved. No architectural blocker remains.