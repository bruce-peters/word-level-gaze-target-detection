-- Adds the ours-vs-Apple's-own-lookAtPoint accuracy comparison recorded by
-- the accuracy-check step (see swift_app/WordGazeAR/AppModel.swift's
-- finishAccuracyCheck, and swift_app/ARKIT_GAZE_RESEARCH.md for why this
-- comparison exists). Nullable/additive only -- older rows and older app
-- builds that don't send these fields are unaffected.

alter table public.reading_sessions
  add column if not exists ours_error_px double precision,
  add column if not exists ours_std_px double precision,
  add column if not exists baseline_error_px double precision,
  add column if not exists baseline_std_px double precision,
  add column if not exists avg_word_width_px double precision;
