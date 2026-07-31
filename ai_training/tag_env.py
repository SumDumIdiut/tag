"""
Gymnasium VecEnv wrapping sim.py's batched simulator for training one
learning agent (seat 0) against an opponent policy in seat 1.

Batched natively (not stable-baselines3's SubprocVecEnv, which spawns one
OS process per env -- unnecessary overhead here since sim.py's own NumPy
vectorization is what buys the real speedup, all in one process, no IPC).
"""

from __future__ import annotations

import numpy as np
from gymnasium import spaces
from stable_baselines3.common.vec_env import VecEnv

from sim import TagSim, ROUND_DURATION_SEC, MAX_FALL_SPEED, DASH_SPEED

# Normalizes position obs -- generous enough to cover the largest of
# sim.py's arenas (the widest reach x:[-1070,1070] once boundary walls are
# added; the_ladder's own floor tier reaches y=500) with margin. Smaller
# arenas just end up using a smaller fraction of the [-1, 1] range -- same
# shared scale for every arena, same reasoning game/npc/trained_policy.gd's
# copy of this constant needs to match exactly (see that file). Left at its
# existing value rather than tightened to the new (smaller, since
# classic_arena's own larger bounds are gone) actual maximum -- shrinking
# it would rescale what every position observation numerically means,
# which the already-trained pool's weights don't expect; margin costs
# nothing, a rescale would cost real accumulated training.
ARENA_HALF_EXTENT = np.array([1250.0, 550.0], dtype=np.float32)


def _opponent_scripted_action(sim: TagSim) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """A simple always-available scripted opponent for seat 1: chase if it,
    flee if not, matching game/npc/npc.gd's own core logic (minus the
    waypoint-graph macro-navigation -- straight-line steering is a
    reasonable opponent for training purposes, not a claim this matches the
    real bot's full behavior)."""
    b = sim.b
    self_pos = sim.pos[:, 1, :]
    other_pos = sim.pos[:, 0, :]
    to_other = other_pos - self_pos
    am_it = sim.is_it[:, 1]

    chase_sign = np.sign(to_other[:, 0])
    flee_sign = -np.sign(to_other[:, 0])
    dir_sign = np.where(am_it, chase_sign, flee_sign)
    move = np.where(dir_sign > 0, 2, np.where(dir_sign < 0, 0, 1)).astype(np.int64)

    dist = np.linalg.norm(to_other, axis=-1)
    jump = (sim.on_floor[:, 1] & (np.random.random(b) < 0.05)).astype(np.int64)
    dash = ((am_it & (dist > 150.0) & (np.random.random(b) < 0.03)) |
            (~am_it & (dist < 120.0) & (np.random.random(b) < 0.15))).astype(np.int64)
    return move, jump, dash


class TagVecEnv(VecEnv):
    """`num_envs` parallel 1v1 matches, seat 0 is the learning agent. One
    episode = one full ROUND_DURATION_SEC round, auto-resetting."""

    def __init__(self, num_envs: int):
        self.sim = TagSim(num_envs)
        # self pos(2)+vel(2)+on_floor(1)+is_it(1)+dash_ready(1) + other
        # rel_pos(2)+vel(2)+is_it(1) + time_remaining(1) = 13.
        observation_space = spaces.Box(low=-1.0, high=1.0, shape=(13,), dtype=np.float32)
        # move_dir(3) x jump(2) x dash(2) -- matches Player.apply_input()'s
        # real input shape (move_dir.x, jump_pressed, dash_pressed).
        action_space = spaces.MultiDiscrete([3, 2, 2])
        super().__init__(num_envs, observation_space, action_space)
        self.render_mode = None
        self._actions = None
        self._episode_reward = np.zeros(num_envs, dtype=np.float32)
        self._episode_len = np.zeros(num_envs, dtype=np.int64)

    def _obs(self) -> np.ndarray:
        s = self.sim
        # DASH_SPEED (not just MOVE_SPEED) is the real max horizontal speed
        # -- normalizing by anything smaller would push a dashing player's
        # velocity outside the declared [-1, 1] Box during exactly the
        # moments (dashes) most relevant to actually observe well.
        vel_norm = np.array([DASH_SPEED, MAX_FALL_SPEED], dtype=np.float32)
        self_pos = s.pos[:, 0, :] / ARENA_HALF_EXTENT
        self_vel = s.vel[:, 0, :] / vel_norm
        other_rel = (s.pos[:, 1, :] - s.pos[:, 0, :]) / (ARENA_HALF_EXTENT * 2.0)
        other_vel = s.vel[:, 1, :] / vel_norm
        return np.concatenate([
            self_pos, self_vel,
            s.on_floor[:, 0:1].astype(np.float32),
            s.is_it[:, 0:1].astype(np.float32),
            (s.dash_cooldown[:, 0:1] <= 0.0).astype(np.float32),
            other_rel, other_vel,
            s.is_it[:, 1:2].astype(np.float32),
            (s.time_remaining[:, None] / ROUND_DURATION_SEC),
        ], axis=-1).astype(np.float32)

    def reset(self):
        self.sim.reset(np.arange(self.num_envs))
        self._episode_reward[:] = 0.0
        self._episode_len[:] = 0
        return self._obs()

    def step_async(self, actions: np.ndarray) -> None:
        self._actions = actions

    def step_wait(self):
        s = self.sim
        move0, jump0, dash0 = self._actions[:, 0], self._actions[:, 1], self._actions[:, 2]
        move1, jump1, dash1 = _opponent_scripted_action(s)

        move = np.stack([move0, move1], axis=1)
        jump = np.stack([jump0, jump1], axis=1)
        dash = np.stack([dash0, dash1], axis=1)

        tagged_this_step, done = s.step(move, jump, dash)

        # Reward: minimize your own time-as-it (the real scoring metric,
        # see tag_mode.gd's it_time) -- penalized per tick while it, a small
        # shaping bonus per tick while not, and an immediate bonus/penalty
        # the instant a tag actually lands (sparse 180s-episode outcomes
        # alone would be far too slow a signal to learn from).
        reward = np.where(s.is_it[:, 0], -1.0 / 60.0, 0.2 / 60.0).astype(np.float32)
        reward += np.where(tagged_this_step[:, 1], 2.0, 0.0).astype(np.float32)  # WE just tagged them -- good
        reward -= np.where(tagged_this_step[:, 0], 2.0, 0.0).astype(np.float32)  # they just tagged US -- bad

        self._episode_reward += reward
        self._episode_len += 1

        obs = self._obs()
        infos = [{} for _ in range(self.num_envs)]
        done_ids = np.nonzero(done)[0]
        if len(done_ids) > 0:
            for i in done_ids:
                infos[i]["episode"] = {"r": float(self._episode_reward[i]), "l": int(self._episode_len[i])}
                infos[i]["it_time_self"] = float(s.it_time[i, 0])
                infos[i]["it_time_opp"] = float(s.it_time[i, 1])
            s.reset(done_ids)
            self._episode_reward[done_ids] = 0.0
            self._episode_len[done_ids] = 0
            obs = self._obs()

        return obs, reward, done, infos

    # VecEnv's process-management API -- all no-ops here, everything runs
    # in-process (see module docstring for why).
    def close(self) -> None:
        pass

    def get_attr(self, attr_name, indices=None):
        return [getattr(self, attr_name)] * self.num_envs

    def set_attr(self, attr_name, value, indices=None) -> None:
        setattr(self, attr_name, value)

    def env_method(self, method_name, *method_args, indices=None, **method_kwargs):
        return [getattr(self, method_name)(*method_args, **method_kwargs)] * self.num_envs

    def env_is_wrapped(self, wrapper_class, indices=None):
        return [False] * self.num_envs

    def get_images(self):
        return [None] * self.num_envs
