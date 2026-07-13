# FretVision — Approved Pass 1 Baseline
 
**Status:** Approved and binding for Pass 2 and implementation. No unresolved architectural blockers remain.
 
This document consolidates the approved Pass 1 baseline and all ratified amendments. Later documents may refine implementation details, but must not contradict the decisions below unless a direct contradiction is explicitly identified.
 
## 1. Ratified MVP assumptions
 
| ID | Binding decision |
|---|---|
| **A-CV1** | Fretboard calibration uses a one-time **manual four-point calibration**: nut/low-E, nut/high-E, 12th-fret/low-E, and 12th-fret/high-E. These points establish an image-to-canonical-fretboard homography. The camera and guitar remain static during a session. |
| **A-COV1** | Coverage metrics are finalized only for `completed` sessions. An `abandoned` session has `scoring_status = insufficient_coverage` and no final `session_metrics` row. |
| **A-SAMP1** | The client emits exactly one `session_samples` record for each completed sampling interval, whether valid or invalid. Invalid intervals still occupy a sequence position. Accuracy is computed over valid samples only. |
| **A-DUR1** | Expected-sample calculations use client-measured monotonic `active_duration_ms`, not server completion receipt time. Offline synchronization delay is never counted as practice duration. |
 
## 2. Accuracy Metric v1
 
### 2.1 MVP operating restrictions
 
- One fixed camera angle per session.
- One guitar in frame.
- Standard six-string guitar.
- Frets 1–12.
- No capo.
- One selected fretting handedness per session.
- Chord-shape/finger-placement accuracy only; no audio correctness.
- Raw webcam frames and full per-frame landmarks remain in the browser.
### 2.2 Coordinate system and calibration
 
The browser normalizes camera mirroring, selected handedness, image rotation, and fretboard orientation into a canonical fretboard coordinate system. Scoring operates on fretboard-relative coordinates, never raw image coordinates.
 
A manual four-point calibration produces a homography from image coordinates to the canonical fretboard plane. The calibration is valid only while the camera and guitar remain sufficiently static.
 
### 2.3 Per-interval scoring
 
At each declared sampling interval, the client produces one interval record. A record is either:
 
- **Valid:** contains a placement-accuracy scalar and confidence value.
- **Invalid:** contains an invalid reason and no placement-accuracy value.
Invalid reasons include low confidence, occlusion, hand or fretboard out of frame, missing fretboard localization, or wrong-hand detection. Invalid intervals are excluded from placement-accuracy calculation and are never treated as zero-accuracy samples.
 
The browser performs per-sample landmark interpretation and placement scoring because raw landmarks and video remain local. The backend cannot independently verify physical finger placement.
 
### 2.4 Required final outputs
 
The five final outputs are stored once per completed session:
 
- `placement_accuracy`: mean accuracy across valid samples only; nullable when there are no valid samples.
- `valid_sample_ratio`: valid coverage relative to expected sampling intervals.
- `confidence_mean`: mean confidence across valid samples; nullable when there are no valid samples.
- `coverage_duration_ms`: duration represented by effective valid samples.
- `invalid_reason_counts`: count per invalid-reason category.
Accuracy and measurement coverage must remain separate. A high accuracy from a small number of valid samples does not imply a successfully scored session.
 
### 2.5 Deterministic coverage and scoring rules
 
The client selects one sampling interval between 2,000 and 5,000 ms at session start. It remains fixed for the full session.
 
```text
expected_sample_count  = floor(active_duration_ms / declared_interval_ms)
submitted_sample_count = count(session_samples)
valid_sample_count     = count(session_samples where is_valid)
effective_valid_count  = min(valid_sample_count, expected_sample_count)
valid_sample_ratio     = expected_sample_count = 0
                         ? 0
                         : effective_valid_count / expected_sample_count
coverage_duration_ms   = effective_valid_count * declared_interval_ms
```
 
An incomplete trailing interval contributes no expected sample and no coverage.
 
For a completed session:
 
```text
scoring_status = scored
  only when valid_sample_ratio >= 0.60
  and coverage_duration_ms >= 120000
 
otherwise scoring_status = insufficient_coverage
```
 
Threshold evaluation and aggregate calculation are server-side. Per-sample scores remain physically untrusted client inputs.
 
## 3. Timing model
 
| Field | Source | Trust and purpose |
|---|---|---|
| `activated_at` | Server | Authoritative session activation timestamp. |
| `active_duration_ms` | Client monotonic timer | Structurally validated but physically untrusted practice duration. |
| `ended_at_client` | Client wall clock | Sanity-check and display input only. |
| `completion_received_at` | Server | Authoritative operational receipt timestamp. |
| `sync_delay_ms` | Derived/diagnostic | Never included in practice duration or coverage. Nullable when unreliable. |
 
Validation rules include:
 
- `active_duration_ms > 0`.
- Maximum MVP duration: 90 minutes.
- Declared interval must remain within 2–5 seconds and cannot change mid-session.
- Submitted samples must be compatible with expected count using a tolerance of `max(2, ceil(expected_sample_count × 0.05))`.
- Client wall-clock sanity check allows approximately ±5 minutes of skew.
- Offline completion delay is excluded from expected-sample calculation.
- `sync_delay_ms` must be non-negative within accepted tolerance; otherwise it is stored as `NULL` diagnostic data.
## 4. Sequence and batching rules
 
- `seq` is zero-based and unique within a session.
- The complete session sample set must be contiguous from zero.
- Invalid intervals still create rows and therefore never create sequence gaps.
- Sample-count tolerance applies only to total submitted count versus expected count, not internal sequence gaps.
- Interval summaries are buffered locally and uploaded in ordered batches, not written once per interval.
- Each batch and completion request uses an idempotency key.
- Practice continues locally when offline; upload is deferred and retried after reconnection.
- Completion is refused until all required contiguous sample chunks have been persisted.
## 5. Session lifecycle and cardinality
 
The lifecycle is:
 
```text
created → active → completed
                ↘ abandoned
```
 
For the MVP:
 
- There is **no separate `attempts` entity**.
- One session is one continuous practice period against exactly one immutable `exercise_revision` and one `target_position_revision`.
- `sessions : session_samples = 1 : N`.
- `sessions : session_metrics = 1 : 0..1`; the metrics row exists only for completed sessions.
- Coverage thresholds and the five final metric outputs are session-level.
- An attempt tier may be introduced only when one future session can contain multiple exercises or targets.
## 6. Trust posture
 
Browser-generated interval records are untrusted. FastAPI may validate and aggregate them, but cannot prove that their placement values correspond to the user’s real physical performance.
 
FastAPI validates:
 
- Authenticated user and session ownership.
- Session state transitions.
- Exercise and target revision identifiers.
- Score and confidence ranges.
- Timestamp and monotonic-offset ordering.
- Fixed declared sampling interval.
- Sequence uniqueness and full contiguity.
- Sample count versus active duration.
- Payload schema and size.
- Idempotency and replay behavior.
- Internal aggregate consistency.
FastAPI computes the authoritative session aggregate and `scoring_status`. It does not accept a client aggregate as authoritative. Optional client preview metrics are diagnostic only and are not persisted as the official result.
 
Anti-cheat and independently verified physical performance are explicit MVP non-goals.
 
## 7. Conceptual entities and trust boundaries
 
### Catalog: authenticated read, admin/migration write
 
- `instruments`
- `lessons`
- `exercises`
- `exercise_revisions`
- `target_position_revisions`
- Target string-position definitions
Published revisions are immutable. Historical sessions reference the exact exercise and target revisions used for scoring. Structural revision integrity must be enforced using a composite foreign key so the target revision is guaranteed to belong to the selected exercise revision.
 
### User-owned: isolated by user identity
 
- `profiles`
- `sessions`
- `session_samples`
- `session_metrics`
- Invalid-reason breakdowns
- Idempotency records
The browser may directly read approved tables and views through Supabase RLS. Backend-mediated writes use the authenticated JWT subject as the ownership source. The browser never receives privileged database or Supabase secret credentials.
 
### Derived server-authoritative data
 
`session_metrics` is computed by FastAPI from structurally validated, physically untrusted `session_samples`. The server guarantees arithmetic consistency and lifecycle enforcement, not physical truth.
 
## 8. Approved architectural boundaries
 
- Browser: webcam access, MediaPipe/OpenCV processing, calibration, coordinate canonicalization, per-sample scoring, overlay rendering, local buffering, and offline continuation.
- FastAPI: JWT verification, authorization, transactional session commands, idempotency, validation, authoritative aggregation, and persistence.
- Supabase PostgreSQL: normalized relational data, constraints, RLS, immutable revisions, and direct authenticated reads.
- REST is the default transport. WebSockets, SSE, and WebRTC are not required for the MVP practice loop.
- Raw video and full per-frame landmarks are never uploaded or persisted.
## 9. Approval state
 
The following decisions are locked for Pass 2 and implementation:
 
- Manual four-point calibration.
- Session-level coverage and metrics.
- One sample row per completed interval, valid or invalid.
- Offline-safe monotonic active duration.
- No attempt tier in MVP.
- Server-authoritative aggregates from physically untrusted client samples.
- Zero-based contiguous sample sequence.
- Floor-based expected-sample convention.
- Accepted clock-skew and sample-count tolerances.
**No architectural blockers remain for Pass 2.**