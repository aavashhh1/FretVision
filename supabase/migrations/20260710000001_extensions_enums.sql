-- ============================================================
-- 0001 — Extensions + Enums
-- Fresh-database migration. No corrective ALTER/DROP.
-- idem_state deliberately has NO 'failed' member (persisted 'failed'
-- is a superseded decision; failures roll back the whole transaction).
-- ============================================================

create extension if not exists pgcrypto;

create type session_lifecycle as enum ('created', 'active', 'completed', 'abandoned');

create type scoring_status as enum ('scored', 'insufficient_coverage');

create type invalid_reason as enum (
  'low_confidence',
  'out_of_frame',
  'occlusion',
  'missing_fretboard',
  'wrong_hand'
);

create type fretting_hand as enum ('left', 'right');

create type string_action as enum ('fretted', 'open', 'muted', 'ignored');

create type idem_state as enum ('processing', 'completed');