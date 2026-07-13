-- ============================================================
-- 0005 — Security-invoker views
-- Applies after 0001–0004. No role references; grants live in 0006.
-- security_invoker = true => the caller's RLS policies apply to the
-- underlying tables. For `authenticated`, sessions/session_metrics RLS
-- restricts the scan to the caller's own rows *before* aggregation, so
-- the grouped view cannot expose another user's totals. No explicit
-- auth.uid() predicate is used; RLS is the isolation boundary.
-- ============================================================

-- Latest published revision per exercise.
create view public.v_latest_published_revision
  with (security_invoker = true)
as
select distinct on (er.exercise_id)
  er.exercise_id,
  er.id                      as exercise_revision_id,
  er.revision_no,
  er.title_snapshot,
  er.instructions,
  er.accuracy_metric_version,
  er.calibration_method,
  er.instrument_id_snapshot,
  er.published_at,
  e.lesson_id,
  e.title                    as exercise_title
from public.exercise_revisions er
join public.exercises e on e.id = er.exercise_id
where er.published
order by er.exercise_id, er.revision_no desc;

-- Aggregate practice summary, one row per user_id.
--   completed_session_count   : sessions in the terminal 'completed' state.
--   scored_session_count      : completed sessions whose server-derived
--                               scoring_status is 'scored'.
--   total_practice_ms         : sum of client-monotonic active_duration_ms
--                               over completed sessions. Structurally
--                               validated, physically untrusted.
--   average_placement_accuracy: mean over sessions that are completed AND
--                               scored AND carry a non-null
--                               placement_accuracy. A completed session that
--                               fell below the coverage thresholds
--                               ('insufficient_coverage') is excluded, so a
--                               high accuracy from a thinly covered session
--                               cannot inflate the user's average. NULL when
--                               no qualifying session exists.
create view public.v_user_practice_summary
  with (security_invoker = true)
as
select
  s.user_id,
  count(*) filter (
    where s.lifecycle = 'completed'::public.session_lifecycle
  )::int                                          as completed_session_count,
  count(*) filter (
    where s.lifecycle = 'completed'::public.session_lifecycle
      and s.scoring_status = 'scored'::public.scoring_status
  )::int                                          as scored_session_count,
  coalesce(
    sum(s.active_duration_ms) filter (
      where s.lifecycle = 'completed'::public.session_lifecycle
    ),
    0
  )::bigint                                       as total_practice_ms,
  avg(m.placement_accuracy) filter (
    where s.lifecycle = 'completed'::public.session_lifecycle
      and s.scoring_status = 'scored'::public.scoring_status
      and m.placement_accuracy is not null
  )::double precision                             as average_placement_accuracy
from public.sessions s
left join public.session_metrics m on m.session_id = s.id
group by s.user_id;