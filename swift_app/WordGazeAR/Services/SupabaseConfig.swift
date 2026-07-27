// Supabase project connection details for the reading_sessions table --
// see supabase/migrations/0001_reading_sessions.sql at the repo root for the
// schema this is meant to insert into.
//
// The anon key is meant to be embedded in client apps (it's the public,
// rate-limited key) -- what actually keeps this "secure-ish" is the
// insert-only Row Level Security policy on the table itself (see the
// migration), not secrecy of this string. It's a JWT signed with the
// project's ref baked into it and role: "anon" -- it can only do what RLS
// policies allow the anon role to do.
enum SupabaseConfig {
    static let projectURL = "https://tdmrtqoykacbelbbjpxd.supabase.co"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRkbXJ0cW95a2FjYmVsYmJqcHhkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUxNTI2NTYsImV4cCI6MjEwMDcyODY1Nn0.uWDgRxb3LDPdElZAvxwKulQMoBZHIvkkmUe6g0NPR_U"

    static var isConfigured: Bool { !anonKey.isEmpty }
}
