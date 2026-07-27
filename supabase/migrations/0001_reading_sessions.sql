-- Reading-session data collected by swift_app/WordGazeAR: one row per
-- finished session, matching ReadingSessionPayload (see
-- swift_app/WordGazeAR/Models/ReadingSessionPayload.swift) field for field.
--
-- Row Level Security is enabled with an insert-only policy for the `anon`
-- role -- the on-device Supabase anon key (see
-- swift_app/WordGazeAR/Services/SupabaseConfig.swift) can write new
-- sessions but can't read back anyone's data, including its own. Query the
-- table from the Supabase dashboard / SQL editor (which uses the service
-- role, bypassing RLS) or add a scoped select policy later if the app
-- itself ever needs to read this data back.

create table if not exists public.reading_sessions (
  id uuid primary key,
  created_at timestamptz not null default now(),

  participant_name text not null,
  participant_age int,
  reading_proficiency text not null check (reading_proficiency in ('low', 'medium', 'high')),

  passage_id text not null,
  passage_title text not null,
  passage_difficulty text not null check (passage_difficulty in ('easy', 'medium', 'long')),

  started_at timestamptz not null,
  finished_at timestamptz not null,
  duration_seconds double precision not null,
  word_count int not null,

  -- Arrays of {word_index, word, seconds}. heatmap is fixations aggregated
  -- by word_index (total dwell per word); fixations is the ordered visit
  -- trail (revisits appear again).
  heatmap jsonb not null,
  fixations jsonb not null,

  device_model text,
  app_version text
);

alter table public.reading_sessions enable row level security;

create policy "anon insert only" on public.reading_sessions
  for insert
  to anon
  with check (true);
