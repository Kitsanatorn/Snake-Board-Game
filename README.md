# Benjakitti Snakes & Ladders

Snakes & Ladders themed on Bangkok's Benjakitti Park, for 2-4 players.

Run: open `benjakitti-snakes-ladders.html` in a browser.

## Online setup (Supabase)

1. Create a Supabase project.
2. SQL Editor: paste `supabase/schema.sql`, run once.
3. Authentication > Providers > Google: enable, paste Google OAuth client ID and secret
   (Google Cloud Console > Credentials > OAuth client, redirect URI = the callback URL Supabase shows).
4. Authentication > URL Configuration: add the URL where the game is hosted.

Stats per player: `select * from player_stats` (games_played, wins, win_rate_percent).
