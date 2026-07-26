#!/usr/bin/env python3
"""
Distributed-training worker (Phase 1/2 of the resource-pool design -- see
ai_training/README.md and learner.py). Pull-only: never listens on a
port, only ever originates outbound requests to the learner, so no
inbound firewall rule is needed on the machine this runs on. Polls the
learner for the current round; if the learner's "dedicate" flag for this
worker is off, sleeps and polls again without doing any work; if on,
loads the learner's current weights, runs stable-baselines3's own
(unmodified) collect_rollouts() against a local TagVecEnv, and submits
the result tagged with that round's id.

Usage:
    python worker.py --learner http://192.168.1.103:8770 --envs 256
"""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.request
import uuid

from stable_baselines3 import PPO

import pool_config as cfg
import pooling
from tag_env import TagVecEnv

DEFAULT_WORKER_ID_FILE = os.path.join(os.path.dirname(__file__), ".worker_id")


def _load_or_create_worker_id(path: str) -> str:
    if os.path.exists(path):
        with open(path, "r") as f:
            existing = f.read().strip()
        if existing:
            return existing
    new_id = str(uuid.uuid4())
    with open(path, "w") as f:
        f.write(new_id)
    return new_id


def _get(url: str, timeout: float = 10.0) -> bytes:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read()


def _post(url: str, data: bytes, timeout: float = 30.0) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--learner", type=str, required=True, help="e.g. http://192.168.1.103:8770")
    parser.add_argument("--envs", type=int, default=32, help="parallel matches this machine simulates each round it's dedicating")
    parser.add_argument("--poll-interval", type=float, default=2.0, help="seconds between /round polls while idle (not dedicating)")
    parser.add_argument("--worker-id-file", type=str, default=DEFAULT_WORKER_ID_FILE)
    args = parser.parse_args()

    worker_id = _load_or_create_worker_id(args.worker_id_file)
    print(f"worker_id={worker_id}")

    env = TagVecEnv(args.envs)
    model = PPO(
        "MlpPolicy", env, verbose=0, device="cpu",
        gamma=cfg.GAMMA, gae_lambda=cfg.GAE_LAMBDA, n_steps=cfg.N_STEPS, batch_size=cfg.BATCH_SIZE,
        policy_kwargs=cfg.POLICY_KWARGS,
    )
    # Same _setup_learn() call as learner.py -- initializes model._last_obs
    # via env.reset() once, so collect_rollouts() has continuous episodes
    # flowing across rounds instead of resetting every round. This
    # worker never trains (never calls model.train()) -- it only exists
    # here to reuse collect_rollouts()'s mechanics with weights loaded in
    # fresh from the learner each round.
    _, callback = model._setup_learn(total_timesteps=10**15, callback=None, reset_num_timesteps=True)

    last_round_seen = -1
    while True:
        try:
            round_info = _get(f"{args.learner}/round?worker_id={worker_id}")
        except OSError as exc:
            # Covers urllib.error.URLError/HTTPError, TimeoutError, and
            # raw socket errors (ConnectionResetError/ConnectionRefusedError
            # -- e.g. the learner restarting or bouncing mid-poll, seen
            # directly during a manual two-process test) -- all retryable,
            # never fatal for a process meant to run indefinitely.
            print(f"learner unreachable ({exc}) -- retrying in {args.poll_interval}s")
            time.sleep(args.poll_interval)
            continue

        info = json.loads(round_info)
        round_id = info["round_id"]
        dedicate = info["dedicate"]

        if not dedicate:
            if last_round_seen != -1:
                print("dedicate flag is off -- idling")
                last_round_seen = -1
            time.sleep(args.poll_interval)
            continue

        if round_id == last_round_seen:
            # Already contributed to this round (or it hasn't advanced
            # yet) -- avoid double-submitting the same round.
            time.sleep(args.poll_interval)
            continue

        try:
            weights_bytes = _get(f"{args.learner}/weights")
            model.policy.load_state_dict(pooling.deserialize_weights(weights_bytes), strict=True)

            local_rollout = pooling.collect_local_rollout(model, env, callback, n_steps=info["n_steps"])
            payload = pooling.serialize_contribution(local_rollout)
            n_episodes = int(local_rollout["episode_starts"].sum())

            status, resp_body = _post(
                f"{args.learner}/contribute?round_id={round_id}&worker_id={worker_id}&episodes={n_episodes}",
                payload,
            )
            if status == 200:
                print(f"[round {round_id}] contributed {args.envs} envs")
                last_round_seen = round_id
            else:
                print(f"[round {round_id}] rejected ({status}): {resp_body.decode(errors='replace')}")
        except OSError as exc:
            print(f"contribute failed ({exc}) -- will retry next poll")


if __name__ == "__main__":
    main()
