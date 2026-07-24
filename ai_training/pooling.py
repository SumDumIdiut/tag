"""
Pure helpers shared by learner.py and worker.py: running one machine's
local rollout collection, and (de)serializing the results for transport
over plain HTTP. No networking and no global state lives here -- see
learner.py/worker.py for those.

Wire format is deliberately numpy-only (np.savez / np.load with
allow_pickle=False), never pickle or torch.save/torch.load -- both of
those deserialize via Python's pickle protocol by default, which is a
known RCE surface for anything other than exactly-trusted bytes. Model
weights travel the same numpy mechanism as rollout data (plain arrays
pulled out of state_dict(), reassembled into tensors on the other end)
so there's one deserialization mechanism to reason about, not two.
"""

from __future__ import annotations

import io

import numpy as np
import torch as th
from stable_baselines3.common.buffers import RolloutBuffer
from stable_baselines3.common.callbacks import BaseCallback

import pool_config as cfg

# The full set collect_local_rollout() returns -- includes rewards/
# episode_starts (needed locally to compute GAE) on top of
# pool_config.POOLED_ARRAY_NAMES (the subset that actually needs to cross
# the network -- see that constant's own comment).
_LOCAL_ONLY_ARRAY_NAMES = ("rewards", "episode_starts")
ALL_ARRAY_NAMES = cfg.POOLED_ARRAY_NAMES + _LOCAL_ONLY_ARRAY_NAMES


def collect_local_rollout(model, env, callback: BaseCallback, n_steps: int = cfg.N_STEPS) -> dict[str, np.ndarray]:
    """Runs stable-baselines3's own (unmodified) collect_rollouts() against
    a local VecEnv, using model's current policy weights. `model` must
    already have gone through _setup_learn() (sets up model._last_obs via
    env.reset() -- collect_rollouts() asserts that's non-None) and
    `callback` should be the callback _setup_learn() returned (safe to
    reuse across every round -- it's the standard SB3 "no callback
    passed" no-op wrapper, not something built fresh each call).
    Returns all 8 RolloutBuffer arrays -- callers that only need to ship
    data over the network should keep just pool_config.POOLED_ARRAY_NAMES
    of them (see serialize_contribution)."""
    buffer = RolloutBuffer(
        n_steps, model.observation_space, model.action_space,
        device=model.device, gamma=cfg.GAMMA, gae_lambda=cfg.GAE_LAMBDA, n_envs=env.num_envs,
    )
    ok = model.collect_rollouts(env, callback, buffer, n_rollout_steps=n_steps)
    if not ok:
        raise RuntimeError("collect_rollouts() was terminated early by its callback")
    return {name: getattr(buffer, name).copy() for name in ALL_ARRAY_NAMES}


def pool_rollouts(contributions: list[dict[str, np.ndarray]], observation_space, action_space, device) -> RolloutBuffer:
    """Concatenates several machines' already-GAE-computed rollouts (each
    a dict covering at least pool_config.POOLED_ARRAY_NAMES, shape
    (n_steps, that_machine's_envs, ...)) along the env axis into one
    RolloutBuffer ready for an unmodified PPO.train() call. Valid because
    RolloutBuffer.compute_returns_and_advantage() computes GAE
    independently per env-column -- pooling the finished per-env-column
    arrays after the fact is mathematically the same as if all the envs
    had been collected by one machine. Every contribution must share the
    same n_steps (pool_config.N_STEPS) -- that's an invariant enforced by
    the caller (learner.py rejects anything tagged with a different
    round's shape), not re-checked here."""
    n_steps = contributions[0][cfg.POOLED_ARRAY_NAMES[0]].shape[0]
    total_envs = sum(c[cfg.POOLED_ARRAY_NAMES[0]].shape[1] for c in contributions)

    pooled = RolloutBuffer(
        n_steps, observation_space, action_space,
        device=device, gamma=cfg.GAMMA, gae_lambda=cfg.GAE_LAMBDA, n_envs=total_envs,
    )
    for name in cfg.POOLED_ARRAY_NAMES:
        setattr(pooled, name, np.concatenate([c[name] for c in contributions], axis=1))
    pooled.pos = n_steps
    pooled.full = True
    return pooled


def serialize_arrays(arrays: dict[str, np.ndarray]) -> bytes:
    buf = io.BytesIO()
    np.savez(buf, **arrays)
    return buf.getvalue()


def deserialize_arrays(data: bytes) -> dict[str, np.ndarray]:
    with np.load(io.BytesIO(data), allow_pickle=False) as npz:
        return {name: npz[name] for name in npz.files}


def serialize_contribution(local_rollout: dict[str, np.ndarray]) -> bytes:
    """Picks just the 6 arrays PPO.train() actually reads (see
    pool_config.POOLED_ARRAY_NAMES) out of collect_local_rollout()'s full
    8-array result -- rewards/episode_starts never need to leave the
    machine that produced them."""
    return serialize_arrays({name: local_rollout[name] for name in cfg.POOLED_ARRAY_NAMES})


def serialize_weights(state_dict: dict[str, th.Tensor]) -> bytes:
    return serialize_arrays({name: tensor.detach().cpu().numpy() for name, tensor in state_dict.items()})


def deserialize_weights(data: bytes) -> dict[str, th.Tensor]:
    return {name: th.from_numpy(arr) for name, arr in deserialize_arrays(data).items()}
