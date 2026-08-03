// Copy this file to config.js (gitignored) and fill in your project's
// service_role key. config.js is loaded by index.html before app.js.
//
// IMPORTANT: this is the SERVICE ROLE key, not the anon key the iOS app
// ships with (see swift_app/WordGazeAR/Services/SupabaseConfig.swift).
// service_role bypasses Row Level Security entirely -- full read/write
// access to the whole database. Get it from the Supabase dashboard:
// Project Settings > API > Project API keys > service_role.
//
// NEVER commit config.js. NEVER deploy this viewer anywhere public with
// that key attached. Treat it like a database password, because it is one.

window.SUPABASE_URL = "https://tdmrtqoykacbelbbjpxd.supabase.co";
window.SUPABASE_SERVICE_KEY = "";
