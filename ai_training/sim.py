"""
Fast, vectorized (NumPy) re-implementation of Tag's core physics and tag
rules, for RL training at far higher than real-time speed -- Godot itself
(even headless, even with Engine.time_scale pushed up) still pays real
per-frame engine overhead per tick; this pays none, and simulates many
environments at once in batched array ops instead of one Godot process per
environment.

Deliberately a SIMPLIFIED subset of game/player/player.gd's real Celeste-
style movement, not a full port: run/friction, gravity (with the real
half-gravity-near-apex hang), jump (with variable height via sustained
velocity), and dash are all here with the real game's own constants
(mirrored below, same values player.gd uses). Wall-jump, climbing, and
corner-correction are NOT simulated -- game/npc/npc.gd's own existing bot
AI never uses any of those three either (it only ever sets move_dir/jump/
dash), so this simulator's action space already matches everything a Tag
bot actually needs to decide.

Arenas: every map in the real online pool (game/levels/online_maps/
catalog.gd / game/levels/local_maps/catalog.gd, both -- every Local map is
also selectable online, see that commit), all 8 -- copied by hand below,
same "single source of truth would be nice but these are genuinely
separate concerns" tradeoff the real catalogs themselves already accept
for each other. 7 of the 8 are generated from a `platforms` rect list
already, copied directly; "classic_arena" (game/levels/tag_arena.tscn) is
hand-built with its collision baked into a TileMapLayer instead, so its
rect list here was produced by game/tools/extract_arena_rects.gd (a
greedy solid-cell-merge over that TileMapLayer) rather than copied from a
catalog -- see that tool if this ever needs regenerating after tag_arena
changes. Its raw output included a redundant, unreachable outer boundary
layer (the tile data has two nested walls a couple hundred units apart;
the inner one already blocks movement, so the outer one is dead
geometry) -- dropped by hand below, everything else is the tool's output
verbatim, plus the two static platforms (PlatformGap/PlatformLift's
replacements, see that commit) it reports separately since they're not
part of the TileMapLayer at all.

reset() below picks a random arena per episode (domain randomization) so
a trained policy generalizes across all of them instead of overfitting to
one specific layout.

Coordinate system, units, and tick rate all match the real game (pixels,
60Hz) so a trained policy's behavior should feel proportionate if/when it's
ever driven inside actual Godot -- see export_weights.py for getting a
trained model's weights out in a form usable there.
"""

import numpy as np

# ─── Physics constants -- mirrors game/player/player.gd exactly ────────────
SCALE = 32.0 / 11.0

MOVE_SPEED = 90.0 * SCALE
GROUND_ACCEL = 1000.0 * SCALE
GROUND_FRICTION = 400.0 * SCALE
AIR_MULT = 0.65
AIR_ACCEL = GROUND_ACCEL * AIR_MULT
AIR_FRICTION = GROUND_FRICTION * AIR_MULT

GRAVITY = 1080.0 * SCALE
MAX_FALL_SPEED = 160.0 * SCALE
HALF_GRAV_THRESHOLD = 40.0 * SCALE

JUMP_VELOCITY = -105.0 * SCALE
JUMP_H_BOOST = 40.0 * SCALE
VAR_JUMP_TIME = 0.2

DASH_SPEED = 240.0 * SCALE * 1.5
DASH_END_SPEED = 160.0 * SCALE
DASH_DURATION = 0.15
DASH_REFILL_COOLDOWN = 0.2

# ─── Tag rules -- mirrors game/modes/tag_mode.gd ────────────────────────────
TAG_DISTANCE = 40.0
IMMUNITY_TIME = 1.0
ROUND_DURATION_SEC = 180.0  # server_match.gd's RANKED_ROUND_DURATION_SEC

TICK_DT = 1.0 / 60.0

# ─── Arenas -- mirrors game/levels/online_maps/catalog.gd's MAPS (the ones
# built from a platforms list -- see module docstring for why classic_arena
# isn't here) plus game/levels/local_maps/catalog.gd's own MAPS (every
# Local map is also in the real online pool). Each row: x0, y0, x1, y1
# (world pixels, same convention as both catalogs).
MAP_PLATFORMS = {
    "square_arena": [
        (-450.0, 420.0, 450.0, 480.0),
        (-300.0, 220.0, -100.0, 240.0),
        (100.0, 220.0, 300.0, 240.0),
        (-120.0, 40.0, 120.0, 60.0),
    ],
    "floating_platforms": [
        (-500.0, 420.0, 500.0, 480.0),
        (-400.0, 260.0, -220.0, 280.0),
        (220.0, 260.0, 400.0, 280.0),
        (-100.0, 100.0, 100.0, 120.0),
    ],
    "wide_open": [
        (-1000.0, 420.0, 1000.0, 480.0),
        (-320.0, 200.0, -100.0, 220.0),
        (100.0, 200.0, 320.0, 220.0),
    ],
    "twin_towers": [
        (-1000.0, 420.0, 1000.0, 480.0),
        (-900.0, 0.0, -800.0, 420.0),
        (800.0, 0.0, 900.0, 420.0),
        (-960.0, -20.0, -740.0, 0.0),
        (740.0, -20.0, 960.0, 0.0),
        (-110.0, 150.0, 110.0, 170.0),
    ],
    "staircase": [
        (-1050.0, 420.0, -750.0, 500.0),
        (-700.0, 340.0, -450.0, 500.0),
        (-400.0, 260.0, -150.0, 500.0),
        (-100.0, 180.0, 150.0, 500.0),
        (200.0, 260.0, 450.0, 500.0),
        (500.0, 340.0, 750.0, 500.0),
        (800.0, 420.0, 1050.0, 500.0),
    ],
    "scattered_islands": [
        (-1000.0, 380.0, -800.0, 420.0),
        (-650.0, 280.0, -450.0, 320.0),
        (-300.0, 380.0, -100.0, 420.0),
        (50.0, 180.0, 250.0, 220.0),
        (350.0, 380.0, 550.0, 420.0),
        (650.0, 280.0, 850.0, 320.0),
        (900.0, 380.0, 1050.0, 420.0),
        (-150.0, 60.0, 150.0, 100.0),
    ],
    "pillars_and_ledges": [
        (-1000.0, 420.0, 1000.0, 480.0),
        (-700.0, 250.0, -650.0, 420.0),
        (-250.0, 300.0, -200.0, 420.0),
        (200.0, 300.0, 250.0, 420.0),
        (650.0, 250.0, 700.0, 420.0),
        (-780.0, 230.0, -600.0, 250.0),
        (600.0, 230.0, 780.0, 250.0),
        (-320.0, 280.0, -160.0, 300.0),
        (160.0, 280.0, 320.0, 300.0),
    ],
    # Extracted from game/levels/tag_arena.tscn's TileMapLayer via
    # game/tools/extract_arena_rects.gd -- see the module docstring above
    # for the redundant-outer-wall-layer it dropped by hand.
    "classic_arena": [
        (-1220.0, -480.0, 1220.0, -440.0),
        (-1220.0, -440.0, -1180.0, 480.0),
        (1180.0, -440.0, 1220.0, 480.0),
        (-1040.0, -130.0, -860.0, -110.0),
        (860.0, -130.0, 1040.0, -110.0),
        (-140.0, -70.0, 140.0, -50.0),
        (-760.0, 150.0, -540.0, 170.0),
        (540.0, 150.0, 760.0, 170.0),
        (-160.0, 300.0, -140.0, 480.0),
        (140.0, 300.0, 160.0, 480.0),
        (-1180.0, 440.0, -160.0, 480.0),
        (-140.0, 440.0, 140.0, 480.0),
        (160.0, 440.0, 1180.0, 480.0),
        (-415.0, 345.0, 415.0, 355.0),  # PlatformGap's static replacement
        (285.0, 15.0, 315.0, 25.0),     # PlatformLift's static replacement
    ],
}
ARENA_IDS = list(MAP_PLATFORMS.keys())
NUM_ARENAS = len(ARENA_IDS)

# Player capsule -- mirrors game/player/player.tscn's RectangleShape2D.
PLAYER_HALF_SIZE = np.array([13.0, 23.5], dtype=np.float32)  # half of (26, 47)

# ─── Derived per-arena boundary walls + spawn points -- ports
# game/tools/generate_online_maps.gd's own _add_boundary_box()/_add_spawns().
# SPAWN_FLOOR_Y specifically uses generate_LOCAL_maps.gd's threshold (360),
# not the online generator's own 420 -- the two real tools actually disagree
# (confirmed by reading both), and every arena here except square_arena/
# floating_platforms was actually built by the LOCAL generator (every Local
# map is also in the online pool now, reusing those exact .tscn files
# rather than regenerating them -- see that commit). 360 is a strict
# superset of what 420 would catch (checked directly against every arena's
# own platform list: nothing between 360-420 exists anywhere except
# scattered_islands' y0=380 floor tier, which is exactly the one that needs
# it -- its real .tscn does have working spawn points, generated with 360),
# so using it for every arena here is safe, not just a special case for
# that one map.
SPAWN_FLOOR_Y = 360.0
WALL_THICKNESS = 20.0
CEILING_CLEARANCE = 300.0


def _boundary_walls(platforms: list) -> list:
    min_x = min(p[0] for p in platforms)
    max_x = max(p[2] for p in platforms)
    min_y = min(p[1] for p in platforms)
    max_y = max(p[3] for p in platforms)
    ceiling_y = min_y - CEILING_CLEARANCE
    return [
        (min_x - WALL_THICKNESS, ceiling_y, min_x, max_y),
        (max_x, ceiling_y, max_x + WALL_THICKNESS, max_y),
        (min_x - WALL_THICKNESS, ceiling_y - WALL_THICKNESS, max_x + WALL_THICKNESS, ceiling_y),
    ]


def _spawn_points(platforms: list) -> list:
    pts = []
    for (x0, y0, x1, y1) in platforms:
        if y0 >= SPAWN_FLOOR_Y:
            width = x1 - x0
            count = max(2, round(width / 260.0))
            for i in range(count):
                t = (i + 0.5) / count
                pts.append((x0 + t * width, y0))
    return pts


# classic_arena's own rect list already includes its real boundary (see the
# module docstring -- extracted straight from the TileMapLayer, not just
# the floor/platforms), so running the generated-boundary formula on top of
# it would wrap a third, even-more-redundant wall layer around the one
# that's already there. Every other arena only lists its floor/platforms,
# same as the real catalogs do, so those still need it computed.
_ARENAS_WITH_OWN_BOUNDARY = {"classic_arena"}
_arena_full_platforms = [
    MAP_PLATFORMS[aid] if aid in _ARENAS_WITH_OWN_BOUNDARY else MAP_PLATFORMS[aid] + _boundary_walls(MAP_PLATFORMS[aid])
    for aid in ARENA_IDS
]
_arena_spawns = [_spawn_points(MAP_PLATFORMS[aid]) for aid in ARENA_IDS]

# Padded (NUM_ARENAS, MAX_PLATFORMS, 4) table -- every arena has a different
# platform count, but _resolve_collisions() below needs one shared shape to
# stay vectorized across the whole batch (different envs can be mid-episode
## on different arenas simultaneously). Padding rows are a degenerate rect
# far off in negative space -- never overlaps a real player position, so
# they're inert without needing a per-arena "how many real platforms" mask.
MAX_PLATFORMS = max(len(p) for p in _arena_full_platforms)
_PAD = -999999.0
ARENA_TABLE = np.full((NUM_ARENAS, MAX_PLATFORMS, 4), _PAD, dtype=np.float32)
for _i, _plats in enumerate(_arena_full_platforms):
    for _j, _p in enumerate(_plats):
        ARENA_TABLE[_i, _j] = _p

# Ragged (one array per arena, since spawn counts differ) -- only indexed in
# reset(), which is per-env-id and infrequent (episode boundaries), so this
# doesn't need to be a padded/vectorized table the way collision does.
ARENA_SPAWNS = [np.array(pts, dtype=np.float32) for pts in _arena_spawns]

# Some real maps (Staircase, Scattered Islands) have genuine gaps between
# platforms with nothing below them -- generate_online_maps.gd's own
# boundary box only ever adds left/right walls + a ceiling, never a floor,
# trusting each map's own platforms to already form one (true for every
# OTHER map here, whose ground platform spans the full width). Confirmed
# this is a real, pre-existing gap in the actual game too, not just this
# simulator: neither player.gd nor server_match.gd has any "fell off the
# level" recovery at all -- a real player falling through one of these
# gaps would just fall forever (the actual game still needs this same fix
# applied server-side, in game/net/server_match.gd -- not done yet).
# FALL_RESPAWN_Y is well below the lowest real platform in each arena, past
# which an episode's agent gets teleported back to a random spawn point
# instead of diverging forever (see TagSim._respawn_fallen()).
FALL_MARGIN = 400.0
ARENA_FALL_Y = np.array(
	[max(p[3] for p in MAP_PLATFORMS[aid]) + FALL_MARGIN for aid in ARENA_IDS],
	dtype=np.float32,
)

# The boundary walls _boundary_walls() generates only span from the ceiling
# down to max_y (the lowest platform's bottom edge) -- they don't extend any
# further down, so once an agent has fallen past that (into one of the real
# gaps above), there's nothing left to collide with horizontally either, and
# it can freely drift sideways while still falling toward ARENA_FALL_Y.
# Confirmed empirically: an agent that fell through a Staircase/Scattered
# Islands gap while holding a direction (or repeatedly dashing) could rack
# up thousands of units of horizontal drift before its Y finally crossed
# ARENA_FALL_Y, well outside the range ARENA_HALF_EXTENT normalizes
# observations for (tag_env.py/trained_policy.gd). A real, in-bounds agent
# can never legitimately pass this -- the walls stop it at min_x/max_x
# (plus half its own width) the entire time it's still above max_y -- so
# this margin only ever fires on exactly this falling-through-a-gap case.
ARENA_X_MARGIN = 100.0
ARENA_X_MIN = np.array([min(p[0] for p in MAP_PLATFORMS[aid]) - ARENA_X_MARGIN for aid in ARENA_IDS], dtype=np.float32)
ARENA_X_MAX = np.array([max(p[2] for p in MAP_PLATFORMS[aid]) + ARENA_X_MARGIN for aid in ARENA_IDS], dtype=np.float32)

# Action indices (matches game/player/player.gd's apply_input() shape).
# move_dir: 0=left, 1=none, 2=right
ACT_MOVE_LEFT, ACT_MOVE_NONE, ACT_MOVE_RIGHT = 0, 1, 2


class TagSim:
    """B parallel 1v1 tag matches, agent axis is always length 2 (index 0 =
    the "learner" seat, index 1 = the "opponent" seat by convention -- the
    sim itself treats both symmetrically, it's only the caller (tag_env.py)
    that assigns meaning to which seat is which)."""

    def __init__(self, batch_size: int):
        self.b = batch_size
        self.pos = np.zeros((self.b, 2, 2), dtype=np.float32)
        self.vel = np.zeros((self.b, 2, 2), dtype=np.float32)
        self.on_floor = np.zeros((self.b, 2), dtype=bool)
        self.facing = np.ones((self.b, 2), dtype=np.float32)
        self.var_jump_timer = np.zeros((self.b, 2), dtype=np.float32)
        self.dash_timer = np.zeros((self.b, 2), dtype=np.float32)
        self.dash_cooldown = np.zeros((self.b, 2), dtype=np.float32)
        self.is_it = np.zeros((self.b, 2), dtype=bool)
        self.it_time = np.zeros((self.b, 2), dtype=np.float32)
        self.immunity_timer = np.zeros(self.b, dtype=np.float32)
        self.time_remaining = np.full(self.b, ROUND_DURATION_SEC, dtype=np.float32)
        # Which of the NUM_ARENAS maps this env is currently playing on --
        # reassigned every reset() (domain randomization), so a training run
        # sees a genuine mix of layouts rather than the same one forever.
        self.arena_id = np.zeros(self.b, dtype=np.int64)
        self.reset(np.arange(self.b))

    def reset(self, env_ids: np.ndarray, arena_ids: np.ndarray = None) -> None:
        """`arena_ids` (optional, shape (len(env_ids),)) pins which arena
        each resetting env uses instead of picking randomly -- mainly for
        testing/debugging a specific layout in isolation; normal training
        never passes this, letting the random domain-randomization default
        happen. Overwriting self.arena_id AFTER calling reset() instead of
        through this is a trap: spawn point selection below already
        happened against whichever arena reset() picked on its own, so a
        post-hoc override leaves the position/geometry mismatched (an
        agent spawned for one arena's layout, colliding against another's
        much-smaller-or-larger walls)."""
        n = len(env_ids)
        if n == 0:
            return
        self.arena_id[env_ids] = arena_ids if arena_ids is not None else np.random.randint(0, NUM_ARENAS, size=n)
        self.vel[env_ids] = 0.0
        self.on_floor[env_ids] = False
        self.var_jump_timer[env_ids] = 0.0
        self.dash_timer[env_ids] = 0.0
        self.dash_cooldown[env_ids] = 0.0
        starter = np.random.randint(0, 2, size=n)
        self.is_it[env_ids] = False
        self.is_it[env_ids, starter] = True
        self.it_time[env_ids] = 0.0
        self.immunity_timer[env_ids] = IMMUNITY_TIME
        self.time_remaining[env_ids] = ROUND_DURATION_SEC
        # Spawn counts differ per arena, so this loops per env (only at
        # episode boundaries -- infrequent, unlike step()'s hot path).
        for env_id in env_ids:
            spawns = ARENA_SPAWNS[self.arena_id[env_id]]
            picks = np.random.choice(len(spawns), size=2, replace=len(spawns) < 2)
            self.pos[env_id, 0] = spawns[picks[0]]
            self.pos[env_id, 1] = spawns[picks[1]]

    def step(self, move_dir: np.ndarray, jump: np.ndarray, dash: np.ndarray):
        """move_dir/jump/dash: shape (B, 2) int/bool arrays, one decision per
        agent per env, already decoded from whatever discrete action a
        policy chose. Returns (tagged_this_step: (B,2) bool -- which agent
        just BECAME it, for reward shaping)."""
        move_x = (move_dir - 1).astype(np.float32)  # 0/1/2 -> -1/0/1
        jump = jump.astype(bool)
        dash = dash.astype(bool)

        nonzero = np.abs(move_x) > 0.01
        self.facing = np.where(nonzero, np.sign(move_x), self.facing)

        dashing = self.dash_timer > 0.0
        can_dash = dash & (~dashing) & (self.dash_cooldown <= 0.0)
        dash_dir = np.where(nonzero, move_x, self.facing)
        self.vel[..., 0] = np.where(can_dash, dash_dir * DASH_SPEED, self.vel[..., 0])
        self.vel[..., 1] = np.where(can_dash, 0.0, self.vel[..., 1])
        self.dash_timer = np.where(can_dash, DASH_DURATION, self.dash_timer)
        self.dash_cooldown = np.where(can_dash, DASH_REFILL_COOLDOWN, self.dash_cooldown)

        still_dashing = (self.dash_timer > 0.0) & (~can_dash)
        dash_ending = still_dashing & (self.dash_timer - TICK_DT <= 0.0)
        end_speed = np.sign(self.vel[..., 0]) * DASH_END_SPEED
        self.vel[..., 0] = np.where(dash_ending, end_speed, self.vel[..., 0])

        active = (~still_dashing) & (~can_dash)
        accel = np.where(self.on_floor, GROUND_ACCEL, AIR_ACCEL)
        friction = np.where(self.on_floor, GROUND_FRICTION, AIR_FRICTION)
        target_speed = move_x * MOVE_SPEED
        moving_toward = np.abs(target_speed) > 0.01
        vx = self.vel[..., 0]
        vx = np.where(
            active & moving_toward,
            vx + np.clip(target_speed - vx, -accel * TICK_DT, accel * TICK_DT),
            vx,
        )
        decel = np.sign(vx) * np.minimum(np.abs(vx), friction * TICK_DT)
        vx = np.where(active & (~moving_toward), vx - decel, vx)
        self.vel[..., 0] = vx

        want_jump = jump & self.on_floor & (~can_dash) & (~still_dashing)
        self.vel[..., 1] = np.where(want_jump, JUMP_VELOCITY, self.vel[..., 1])
        self.vel[..., 0] = np.where(
            want_jump, self.vel[..., 0] + self.facing * JUMP_H_BOOST, self.vel[..., 0]
        )
        self.var_jump_timer = np.where(want_jump, VAR_JUMP_TIME, self.var_jump_timer)
        self.on_floor = self.on_floor & (~want_jump)

        sustaining = (self.var_jump_timer > 0.0) & jump & (self.vel[..., 1] < 0.0)
        vy = self.vel[..., 1]
        near_apex = np.abs(vy) < HALF_GRAV_THRESHOLD
        grav = np.where(near_apex, GRAVITY * 0.5, GRAVITY)
        gravity_active = active & (~sustaining)
        vy = np.where(gravity_active, np.minimum(vy + grav * TICK_DT, MAX_FALL_SPEED), vy)
        self.vel[..., 1] = vy
        self.var_jump_timer = np.maximum(self.var_jump_timer - TICK_DT, 0.0)

        self.pos = self.pos + self.vel * TICK_DT
        self._resolve_collisions()
        self._respawn_fallen()

        self.dash_timer = np.maximum(self.dash_timer - TICK_DT, 0.0)
        self.dash_cooldown = np.maximum(self.dash_cooldown - TICK_DT, 0.0)
        self.immunity_timer = np.maximum(self.immunity_timer - TICK_DT, 0.0)
        self.time_remaining = np.maximum(self.time_remaining - TICK_DT, 0.0)

        self.it_time[self.is_it] += TICK_DT

        tagged_this_step = np.zeros((self.b, 2), dtype=bool)
        dist = np.linalg.norm(self.pos[:, 0, :] - self.pos[:, 1, :], axis=-1)
        can_tag = (self.immunity_timer <= 0.0) & (dist < TAG_DISTANCE)
        if np.any(can_tag):
            it_idx = self.is_it[:, 1].astype(int)  # 0 if agent0 is it, 1 if agent1 is it
            other_idx = 1 - it_idx
            flip = can_tag
            rows = np.nonzero(flip)[0]
            self.is_it[rows, it_idx[rows]] = False
            self.is_it[rows, other_idx[rows]] = True
            tagged_this_step[rows, other_idx[rows]] = True
            self.immunity_timer[rows] = IMMUNITY_TIME

        done = self.time_remaining <= 0.0
        return tagged_this_step, done

    def _resolve_collisions(self) -> None:
        """Simple axis-aligned resolution against each platform, per agent --
        push out along whichever axis has the smaller overlap, same
        "resolve the shallow axis" approach Godot's own move_and_slide
        effectively converges to for these box-on-box cases.

        Different envs can be on different arenas at once (see reset()'s
        domain randomization), so this indexes ARENA_TABLE by each env's
        own arena_id per slot -- x0/y0/x1/y1 below are (B,) arrays (one
        rect per env for this slot), not scalars, but every op on them was
        already elementwise against the (B,)-shaped px/py, so nothing else
        here needed to change. Padding slots (see ARENA_TABLE) are inert:
        a degenerate rect far off in negative space never overlaps a real
        player position, so a slot beyond however many platforms an env's
        own arena actually has just costs a no-op check for that env."""
        self.on_floor[...] = False
        for slot in range(MAX_PLATFORMS):
            plat = ARENA_TABLE[self.arena_id, slot]  # (B, 4): x0,y0,x1,y1 per env
            x0, y0, x1, y1 = plat[:, 0], plat[:, 1], plat[:, 2], plat[:, 3]
            for agent in range(2):
                px, py = self.pos[:, agent, 0], self.pos[:, agent, 1]
                left, right = px - PLAYER_HALF_SIZE[0], px + PLAYER_HALF_SIZE[0]
                top, bottom = py - PLAYER_HALF_SIZE[1], py + PLAYER_HALF_SIZE[1]
                overlap = (right > x0) & (left < x1) & (bottom > y0) & (top < y1)
                if not np.any(overlap):
                    continue
                pen_x = np.minimum(right - x0, x1 - left)
                pen_y = np.minimum(bottom - y0, y1 - top)
                from_top = (py < (y0 + y1) * 0.5)
                use_y = overlap & (pen_y <= pen_x)
                use_x = overlap & (~use_y)

                new_py = np.where(use_y & from_top, y0 - PLAYER_HALF_SIZE[1], py)
                new_py = np.where(use_y & (~from_top), y1 + PLAYER_HALF_SIZE[1], new_py)
                self.pos[use_y, agent, 1] = new_py[use_y]
                self.vel[use_y, agent, 1] = np.where(from_top[use_y], 0.0, self.vel[use_y, agent, 1])
                self.on_floor[:, agent] = self.on_floor[:, agent] | (use_y & from_top)

                from_left = (px < (x0 + x1) * 0.5)
                new_px = np.where(use_x & from_left, x0 - PLAYER_HALF_SIZE[0], px)
                new_px = np.where(use_x & (~from_left), x1 + PLAYER_HALF_SIZE[0], new_px)
                self.pos[use_x, agent, 0] = new_px[use_x]
                self.vel[use_x, agent, 0] = 0.0

    def _respawn_fallen(self) -> None:
        """An agent who fell past their own arena's ARENA_FALL_Y (through a
        real gap -- see that constant's own comment), OR who's drifted past
        ARENA_X_MIN/MAX while doing so (see that constant's own comment --
        the boundary walls stop short once you're below the platforms, so a
        falling agent can otherwise wander sideways indefinitely), gets
        teleported back to a random spawn point on the SAME arena, velocity
        zeroed, same as the fix applied to the real game (server_match.gd).
        Rare in practice (most actions don't walk an agent into one of the
        few gap-y maps' actual gaps), so a small Python-level loop over
        whichever (env, agent) pairs actually fell this tick is fine --
        not worth vectorizing a path that's cold almost every tick."""
        fell = self.pos[:, :, 1] > ARENA_FALL_Y[self.arena_id][:, None]
        out_of_bounds = (
            (self.pos[:, :, 0] < ARENA_X_MIN[self.arena_id][:, None]) |
            (self.pos[:, :, 0] > ARENA_X_MAX[self.arena_id][:, None])
        )
        fell = fell | out_of_bounds
        if not np.any(fell):
            return
        for env_id, agent in zip(*np.nonzero(fell)):
            spawns = ARENA_SPAWNS[self.arena_id[env_id]]
            pick = spawns[np.random.randint(len(spawns))]
            self.pos[env_id, agent] = pick
            self.vel[env_id, agent] = 0.0
