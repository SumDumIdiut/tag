# Drawing for Tag

Every character/hat sprite in the game is editable, and there's a dedicated tool for
doing it -- no game code, no Godot install, no source repo needed.

## Quick start

1. Grab **`TagArtTool.exe`** from the [Releases](../../releases) page (same place as
   `Tag.exe` -- built automatically on every push to `main`, so it's always current).
2. Run it. It already contains every current shape -- torso, head, both arms, both
   legs, and all four hats (cap, beanie, top hat, crown).
3. Pick a part on the left, paint on the canvas in the middle. The panel on the right
   shows a live preview of your edit on the actual character, in three sample colors,
   updating as you paint.
4. Click **Export Edits**. This writes an `edited_templates/` folder next to the .exe,
   with your changes plus a short `HOW_TO_SUBMIT.txt`.
5. Send that folder back (zip it up -- Discord, email, whatever's easiest), or open a
   pull request replacing the matching files under
   `game/assets/character_templates/` (and `.../hats/` for hat files).
6. Once it's merged into `main`, the next automatic build already includes it. That's
   the entire pipeline -- nothing else has to happen.

## The toolset

Brush (1-3px), eraser, flood fill, eyedropper, undo/redo, a color picker, and a
part switcher for all 10 paintable shapes. The three gray swatches above the color
picker (**Base / Shade / Highlight**) are the important ones -- see below.

## Why paint in gray

Each shape isn't tied to one color -- the game recolors it per skin (8 built-in
colors) or per hat automatically. That only works because the *shape* (what you
paint) is separate from the *color* (picked at build time). The three gray swatches
mark which parts of your drawing play which role:

- **Base** -- the character's main skin color goes here.
- **Shade** -- a darker variant (used for arms/legs in the current design).
- **Highlight** -- a lighter variant (used for the head).

Paint in those three exact grays and your edit gets the same clean per-skin shading
the original art already has, automatically, for all 8 colors, with zero extra work.
You're not required to stick to them -- paint in any other color and it still gets a
reasonable per-skin recolor (a straightforward multiply tint), just without the exact
shading trick. Eyes and the crown's jewel are intentionally *not* grayscale in the
templates (they're meant to stay a fixed color no matter the skin), and painting over
them in a real color works the same way.

## Canvas sizes

Every shape has to stay exactly the size it already is (the game crops/positions each
part by exact pixel dimensions) -- the tool won't let you resize a canvas. Body parts
are tiny (14-21px), which is normal for pixel art at this scale: zoom in and work
pixel-by-pixel, the same way you would in any dedicated pixel art tool.

## The technical version, if you're curious

`game/assets/character_templates/` holds the 10 source shapes (what the Art Tool
ships with and edits). `tools/bake_character_art.gd` turns those into the 52 actual
files the game loads (`game/assets/character/`) -- one per skin color per part, plus
one per hat -- via the same gray-marker substitution described above. That bake step
runs automatically as part of every CI build
(`.github/workflows/build.yml`), which is the whole mechanism behind "merge it and
it's just in the next build."

## Designing levels

There's no separate custom tool for this -- Godot's own built-in TileMap editor
already does the job well. `game/levels/tag_tileset.tres` defines the tile set
(3 tiles: boundary/pillar/platform, each with matching physics collision already set
up), and `game/levels/tag_arena.tscn`'s `Tiles` node is a `TileMapLayer` painted with
it. To extend or build a new arena: open the scene in the Godot editor, select the
`Tiles` node, and paint with the TileSet panel at the bottom of the screen (bucket
fill and rectangle-select both work great for platform layouts). Spawn points and the
AI navigation graph are plain `Marker2D` nodes under `SpawnPoints`/`Waypoints` --
add/move them the same way you would any other node. `game/tools/build_tileset.gd`
and `game/tools/convert_arena_to_tiles.gd` are the one-off scripts that built the
current tile set/arena, kept as a reference if you ever want to add new tile types.
