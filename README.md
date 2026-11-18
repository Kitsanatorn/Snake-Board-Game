# Benjakitti Snakes & Ladders

Snakes & Ladders themed on Bangkok's Benjakitti Park, for 2-4 players.

Hot-seat: open `benjakitti-snakes-ladders.html` in a browser.

Online (login needs http, not `file://`): run `npx serve .` and open
`http://localhost:3000/benjakitti-snakes-ladders.html`. Sign in with an email link or Google,
create a room, share the 6-letter code.

## Online setup (Supabase)

1. Create a Supabase project.
2. SQL Editor: paste `supabase/schema.sql`, run once.
3. Authentication > Providers > Google: enable, paste Google OAuth client ID and secret
   (Google Cloud Console > Credentials > OAuth client, redirect URI = the callback URL Supabase shows).
4. Authentication > URL Configuration: add the URL where the game is hosted
   (and `http://localhost:3000/**` for local play) to Redirect URLs.
5. Put the project URL and publishable key in the `createClient(...)` call in the HTML.
   Never the secret key.

Stats per player: `select * from player_stats` (games_played, wins, win_rate_percent).
