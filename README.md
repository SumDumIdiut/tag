# Tag

A multiplayer Tag game built in Godot 4.7, with Celeste-style platforming movement
(coyote time, jump buffering, wall jumps, dashing, climbing) as the core moveset.

## Structure

- `game/` - the Godot project (client, dedicated server, art tool, and local/singleplayer modes all live here; see `game/player/player.gd` for the shared movement code). `game/tools/` holds the in-project scripts (character art template/bake pipeline, tileset builder) -- see [ART_GUIDE.md](ART_GUIDE.md).
- `_archive_multiplayer/` - preserved code from an earlier networking architecture, kept for reference (see its own README).
- `tools/` (repo root) - local dev tooling that runs outside Godot (the editor binary itself is gitignored; PowerShell asset-generation scripts are kept).

## Running it

Open `game/` in the Godot 4.7 editor, or run one of the exported executables from a
[Release](../../releases) (built automatically on every push to `main`):

- **`Tag.exe`** - the client. The main menu offers three destinations: Online, Local,
  and Sandbox, plus a Customize button for skins/hats. It's also the server: Host
  Server, Quick Play, and Ranked auto-host all just spawn a second headless copy of
  this same exe with `--server` (see `game/net/local_server_spawner.gd`), a fully
  authoritative dedicated server over WebSockets (chosen so it can be reached through
  a Cloudflare Tunnel without requiring players to install anything extra). Nothing
  else to download for hosting.
- **`TagArtTool.exe`** - paint over the game's character/hat art, no source repo
  needed. See [ART_GUIDE.md](ART_GUIDE.md).

## Modes

- **Sandbox** - a single-player course for testing the moveset in isolation.
- **Local** - play against up to 7 AI-controlled bots (skill levels 1-5) on one
  machine, no networking involved.
- **Online** - Quick Play or Ranked (both auto-match: join an open server if one
  exists, otherwise host one and wait), or browse/host/direct-connect manually. The
  server runs the authoritative simulation; every client (including the host's own)
  renders confirmed server state rather than predicting locally.

## Building

Export presets are defined in `game/export_presets.cfg`:

- `Windows Desktop` -> client + server, one exe (`builds/Tag.exe`)
- `Art Tool` -> standalone art tool (`builds/TagArtTool.exe`)

Both are one project, distinguished at runtime by a custom feature tag per preset
(`art_tool` / neither -- see `game/main/bootstrap.gd`). The client build additionally
boots straight into the server scene if launched with `--server`, regardless of
feature tag -- that's what lets `Tag.exe` host without a separate server binary.

`.github/workflows/build.yml` runs both exports on every push to `main` and
publishes the results as a GitHub Release. Before exporting, it also re-bakes the
character/hat art from whatever's currently in `game/assets/character_templates/`
(see [ART_GUIDE.md](ART_GUIDE.md)) -- so a merged art edit is already in the very
next build with no extra steps.
