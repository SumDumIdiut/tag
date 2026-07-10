# Tag

A multiplayer Tag game built in Godot 4.7, with Celeste-style platforming movement
(coyote time, jump buffering, wall jumps, dashing, climbing) as the core moveset.

## Structure

- `game/` - the Godot project (client, dedicated server, and local/singleplayer modes all live here; see `game/player/player.gd` for the shared movement code).
- `_archive_multiplayer/` - preserved code from an earlier networking architecture, kept for reference (see its own README).
- `tools/` - local dev tooling (the Godot editor binary itself is gitignored; asset-generation scripts are kept).

## Running it

Open `game/` in the Godot 4.7 editor, or run one of the exported executables from a
[Release](../../releases) (built automatically on every push to `main`):

- **`Tag.exe`** - the client. Main Menu offers local Tag (with AI bots), a movement
  sandbox, and Multiplayer (connects to a dedicated server).
- **`Tag-Server.exe`** - a headless, fully authoritative dedicated server. Hosts any
  number of concurrent lobbies over WebSockets (chosen so it can be reached through a
  Cloudflare Tunnel without requiring players to install anything extra).

## Modes

- **Movement Sandbox** - a single-player course for testing the moveset in isolation.
- **Local Tag** - play against up to 7 AI-controlled bots (skill levels 1-5) on one
  machine, no networking involved.
- **Multiplayer** - connect to a dedicated server, create/join a lobby, ready up, and
  play real-player Tag. The server runs the authoritative simulation; the client
  predicts its own movement locally and reconciles against server snapshots.

## Building

Export presets are defined in `game/export_presets.cfg`:

- `Windows Desktop` -> client (`builds/Tag.exe`)
- `Windows Dedicated Server` -> server (`builds/Tag-Server.exe`), distinguished from
  the client at runtime via the `dedicated_server` custom feature tag (see
  `game/main/bootstrap.gd`)

`.github/workflows/build.yml` runs both exports on every push to `main` and publishes
the results as a GitHub Release.
