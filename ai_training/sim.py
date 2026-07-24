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

Arena: a single hardcoded platform layout mirroring
game/levels/online_maps/catalog.gd's "square_arena" (its exact platform
rects, copied by hand -- see that file if the real catalog ever changes and
this drifts).

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

# ─── Arena -- mirrors game/levels/online_maps/catalog.gd's "square_arena" ──
# Each row: x0, y0, x1, y1 (world pixels, same convention as the catalog).
# The catalog only lists the floating platforms themselves -- the real
# game's actual arena scene additionally has an enclosing boundary (walls
# and a floor) generated around them, same as every online map, that keeps
# a player from ever walking/falling off the playable area entirely. The
# 4 platforms above alone left this simulator with open edges an agent
# could fall through into unbounded space (confirmed: random actions drove
# observations far outside normalized [-1, 1] within a couple hundred
# steps) -- the 3 rows below are that missing enclosure, sized generously
# around the actual platform layout.
PLATFORMS = np.array([
    [-450.0, 420.0, 450.0, 480.0],
    [-300.0, 220.0, -100.0, 240.0],
    [100.0, 220.0, 300.0, 240.0],
    [-120.0, 40.0, 120.0, 60.0],
    [-580.0, -100.0, -550.0, 700.0],  # left wall
    [550.0, -100.0, 580.0, 700.0],    # right wall
    [-580.0, 650.0, 580.0, 700.0],    # floor (safety net below the real ground platform)
], dtype=np.float32)

# Player capsule -- mirrors game/player/player.tscn's RectangleShape2D.
PLAYER_HALF_SIZE = np.array([13.0, 23.5], dtype=np.float32)  # half of (26, 47)

SPAWN_POINTS = np.array([
    [-300.0, 380.0],
    [300.0, 380.0],
], dtype=np.float32)

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
        self.reset(np.arange(self.b))

    def reset(self, env_ids: np.ndarray) -> None:
        n = len(env_ids)
        if n == 0:
            return
        self.pos[env_ids] = SPAWN_POINTS[None, :, :].repeat(n, axis=0)
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
        effectively converges to for these box-on-box cases."""
        self.on_floor[...] = False
        for plat in PLATFORMS:
            x0, y0, x1, y1 = plat
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
