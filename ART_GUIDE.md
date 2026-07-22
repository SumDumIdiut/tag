# Art for Tag

The Art Tool (`TagArtTool.exe`, same [Releases](../../releases) page as `Tag.exe`,
built automatically on every push to `main`) covers everything paintable in the game:
levels, the small menu-bar badge icons, and the shared button/panel/slider chrome.
No game code, no Godot install, no source repo needed.

## Quick start

1. Grab `TagArtTool.exe` from Releases.
2. Pick a tab: **Levels**, or **Sprites** (Menu Icons / Chrome).
3. Paint. Click **Export Edits** (Sprites) or **Publish Map** (Levels) to publish your
   change live -- no rebuild or restart needed for anyone.

## Sprites

**Menu Icons** are the small badge glyphs (globe, controller, bolt, etc.) used
throughout the menus -- painted white/grayscale, since they're re-tinted per usage at
runtime (each screen applies its own accent color).

**Chrome** is the app's shared button/panel/slider box art -- four small 9-patch
pieces (fixed-width border pixels, stretchy middle) reused everywhere at once, also
painted white/grayscale for the same re-tinting reason.

## Designing levels

There's no separate custom tool for this -- Godot's own built-in TileMap editor
already does the job well. `game/levels/tag_tileset.tres` defines the tile set
(3 base types -- boundary/pillar/platform -- each with 3 art variants -- Piece/Corner/
Internal -- for 9 tiles total, all with matching physics collision already set up), and
`game/levels/tag_arena.tscn`'s `Tiles` node is a `TileMapLayer` painted with
it. To extend or build a new arena: open the scene in the Godot editor, select the
`Tiles` node, and paint with the TileSet panel at the bottom of the screen (bucket
fill and rectangle-select both work great for platform layouts). Spawn points and the
AI navigation graph are plain `Marker2D` nodes under `SpawnPoints`/`Waypoints` --
add/move them the same way you would any other node. `game/tools/build_tileset.gd`
and `game/tools/convert_arena_to_tiles.gd` are the one-off scripts that built the
current tile set/arena, kept as a reference if you ever want to add new tile types.

Or use the Art Tool's own **Levels** tab -- paint tiles, drop spawn points, and
publish directly from there without touching the Godot editor at all.
