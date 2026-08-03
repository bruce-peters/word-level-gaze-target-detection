# WordGazeAR Session Viewer

A tiny local-only web page for browsing the reading sessions collected by
the iOS app (`../swift_app/`) and stored in Supabase's `reading_sessions`
table (see `../supabase/migrations/0001_reading_sessions.sql`).

Plain HTML/CSS/JS, no build step, no dependencies — talks to Supabase's
REST API (PostgREST) directly with `fetch()`, the same minimal-dependency
approach `swift_app/WordGazeAR/Services/SupabaseClient.swift` uses on the
app side.

## Why this needs a different key than the app

The app's Supabase anon key can only *insert* rows (see the migration's RLS
policy) — it's meant to be embedded in a shipped app, so it's deliberately
powerless to read data back. This viewer needs to *read* everyone's
sessions, which means it needs the project's **service_role** key instead —
a secret key with full read/write access that bypasses Row Level Security
entirely.

**This means local use only.** Never deploy this viewer anywhere public,
never commit `config.js`, never share the service_role key. Treat it like a
database password, because it is one.

## Setup

1. `cp config.example.js config.js`
2. Open `config.js` and fill in `SUPABASE_SERVICE_KEY` — get it from the
   Supabase dashboard: **Project Settings → API → Project API keys →
   service_role**. `SUPABASE_URL` is already filled in.
3. Serve the **repo root** over HTTP and open the viewer from there — two
   reasons: opening `index.html` directly as a `file://` URL hits CORS
   restrictions on the `fetch()` call in most browsers, and the heatmap
   view fetches `/swift_app/WordGazeAR/passages.json` as an absolute path,
   which only resolves correctly if the server root is the repo root (not
   the `viewer/` folder itself). From the repo root:

   ```
   python3 -m http.server 8000
   ```

   then open `http://localhost:8000/viewer/`.

## Using it

- The table lists every session, newest first: participant, passage,
  duration, word/fixation counts. Type in the filter box to narrow by
  participant name or passage title.
- Click a row to open its detail view:
  - **Heatmap** — the *entire* passage, word for word (pulled from
    `passages.json`, matched by `passage_id`), with each word's background
    darkened by how long it was fixated. Words never fixated stay
    unhighlighted rather than disappearing — earlier versions only rendered
    the words present in the session's `heatmap` column, which silently
    dropped everything else and made sessions with a lot of tracking jumps
    look like only a fragment of the passage was shown. If `passages.json`
    can't be loaded (e.g. not served from the repo root, or the passage
    bank changed since this session was recorded), it falls back to that
    tracked-words-only view with a note saying so.
  - **Show gaze replay** (checkbox above the heatmap) — steps through the
    session's fixation trail in visit order, highlighting each word for its
    recorded dwell time (Play/Pause, Restart, 1x/3x/10x speed). This is
    **word-level**, not the literal per-pixel gaze dot — the raw continuous
    gaze trail the iOS app's own on-device replay shows is deliberately
    never uploaded to Supabase (see
    `swift_app/WordGazeAR/Models/SessionRecorder.swift`), to avoid storing
    a large high-frequency stream for every session. This is as
    fine-grained as a remote/web replay can get without changing that.
  - **Fixation trail** — the same data as the replay, laid out as a plain
    ordered list instead of animated.
- **Download JSON** on a detail view saves that one session's full raw row.
- **Export CSV** (top bar) saves a spreadsheet-friendly summary (one row
  per session, no heatmap/fixation detail) of whatever's currently
  filtered/visible.
- This is read-only by design — no delete/edit here, even though the
  service_role key technically could. If you need to remove a session, do
  it from the Supabase dashboard directly.
