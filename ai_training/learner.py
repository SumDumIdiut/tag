#!/usr/bin/env python3
"""
Distributed-training coordinator (Phase 1/2 of the resource-pool design --
see ai_training/README.md). Holds the canonical PPO model + optimizer
state. Each round: broadcasts current weights + a round id; optionally
runs a small local rollout itself; waits (bounded) for worker
contributions tagged with that round id over plain HTTP; pools everything
together (see pooling.pool_rollouts) into one RolloutBuffer; calls SB3's
own unmodified PPO.train() once against the pooled data. LAN-only, no
auth -- not meant to be reachable from the public internet (see
README.md's security note).

Usage:
    python learner.py --port 8770 --local-envs 4
    python learner.py --port 8770 --local-envs 4 --resume models/npc_v1.zip --out models/pooled
    python learner.py --port 8770 --local-envs 4 --rounds 5   # for testing -- exits after N rounds
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from stable_baselines3 import PPO

import pool_config as cfg
import pooling
from export_weights import export_policy
from tag_env import TagVecEnv


class LearnerState:
    """All mutable state the HTTP handler threads and the main training-
    loop thread touch together -- guarded by one lock. The training loop
    owns round_id/weights_bytes (only it advances rounds); handler
    threads only ever append to contributions or update dedicate_flags/
    last_seen, keyed by a worker-supplied id."""

    def __init__(self, model):
        self.lock = threading.Lock()
        self.model = model
        self.round_id = 0
        self.weights_bytes = b""
        self.contributions: list[dict] = []  # [{worker_id, arrays}] for the CURRENTLY open round only
        self.dedicate_flags: dict[str, bool] = {}
        self.last_seen: dict[str, dict] = {}  # worker_id -> {"time": epoch, "envs": int}


def make_handler(state: LearnerState):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass  # the training loop prints its own round-by-round summary; keep stdout readable

        def _json(self, obj, status=200):
            body = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _binary(self, data: bytes, status=200):
            self.send_response(status)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            parsed = urlparse(self.path)
            qs = parse_qs(parsed.query)
            if parsed.path == "/round":
                worker_id = qs.get("worker_id", [""])[0]
                with state.lock:
                    dedicate = state.dedicate_flags.get(worker_id, False)
                    self._json({"round_id": state.round_id, "n_steps": cfg.N_STEPS, "dedicate": dedicate})
            elif parsed.path == "/weights":
                with state.lock:
                    data = state.weights_bytes
                self._binary(data)
            elif parsed.path == "/status":
                with state.lock:
                    self._json({
                        "round_id": state.round_id,
                        "num_timesteps": int(state.model.num_timesteps),
                        "workers": {
                            wid: {
                                "last_seen": info["time"],
                                "envs": info["envs"],
                                "dedicate": state.dedicate_flags.get(wid, False),
                            }
                            for wid, info in state.last_seen.items()
                        },
                    })
            else:
                self._json({"error": "not found"}, status=404)

        def do_POST(self):
            parsed = urlparse(self.path)
            qs = parse_qs(parsed.query)
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else b""

            if parsed.path == "/contribute":
                worker_id = qs.get("worker_id", [""])[0]
                try:
                    round_id = int(qs.get("round_id", ["-1"])[0])
                except ValueError:
                    round_id = -1
                with state.lock:
                    current_round = state.round_id
                    if round_id != current_round:
                        self._json({"accepted": False, "reason": f"stale round_id {round_id}, current is {current_round}"}, status=409)
                        return
                    try:
                        arrays = pooling.deserialize_arrays(body)
                        n_steps = arrays[cfg.POOLED_ARRAY_NAMES[0]].shape[0]
                        n_envs = arrays[cfg.POOLED_ARRAY_NAMES[0]].shape[1]
                    except Exception as exc:
                        self._json({"accepted": False, "reason": f"bad payload: {exc}"}, status=400)
                        return
                    if n_steps != cfg.N_STEPS:
                        self._json({"accepted": False, "reason": f"n_steps {n_steps} != expected {cfg.N_STEPS}"}, status=400)
                        return
                    state.contributions.append({"worker_id": worker_id, "arrays": arrays})
                    state.last_seen[worker_id] = {"time": time.time(), "envs": n_envs}
                self._json({"accepted": True})
            elif parsed.path == "/dedicate":
                worker_id = qs.get("worker_id", [""])[0]
                on = qs.get("on", ["false"])[0].lower() == "true"
                with state.lock:
                    state.dedicate_flags[worker_id] = on
                self._json({"ok": True, "dedicate": on})
            else:
                self._json({"error": "not found"}, status=404)

    return Handler


def _publish_weights(model, path: str) -> None:
    """Writes to `path` atomically (temp file + os.replace) so a
    concurrent GET from relay-server -- a separate process, reading this
    same path to serve /api/ai/policy-weights -- never observes a
    partially-written file mid-export."""
    tmp_path = path + ".tmp"
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    export_policy(model.policy, tmp_path)
    os.replace(tmp_path, path)


def run_round(state: LearnerState, env, callback, local_envs: int, round_timeout_sec: float) -> int:
    """Runs one full round: broadcast, collect (local + wait for
    workers), pool, train. Returns the number of envs that contributed
    this round (0 means nobody did -- caller should skip training).
    Always waits the full timeout (no early-exit-once-someone-answered
    heuristic) -- simpler to reason about and to test deterministically;
    latency isn't the concern this design optimizes for."""
    model = state.model

    with state.lock:
        state.round_id += 1
        state.contributions = []
        round_id = state.round_id
        state.weights_bytes = pooling.serialize_weights(model.policy.state_dict())

    local_contribution = None
    if local_envs > 0:
        local_contribution = pooling.collect_local_rollout(model, env, callback, n_steps=cfg.N_STEPS)

    deadline = time.monotonic() + round_timeout_sec
    while time.monotonic() < deadline:
        time.sleep(0.2)

    with state.lock:
        worker_contribs = [c["arrays"] for c in state.contributions if c["arrays"][cfg.POOLED_ARRAY_NAMES[0]].shape[0] == cfg.N_STEPS]

    all_contribs = ([{k: local_contribution[k] for k in cfg.POOLED_ARRAY_NAMES}] if local_contribution else []) + worker_contribs
    if not all_contribs:
        print(f"[round {round_id}] nobody contributed -- skipping this round's train()")
        return 0

    pooled = pooling.pool_rollouts(all_contribs, model.observation_space, model.action_space, model.device)
    total_envs = pooled.observations.shape[1]

    model.rollout_buffer = pooled
    model.train()
    model.num_timesteps += cfg.N_STEPS * total_envs

    print(f"[round {round_id}] total_envs={total_envs} (local={local_envs if local_contribution else 0}, "
          f"workers={len(worker_contribs)}) num_timesteps={model.num_timesteps:,}")
    return total_envs


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8770)
    parser.add_argument("--local-envs", type=int, default=4, help="parallel matches this machine itself simulates each round, in addition to whatever workers submit")
    parser.add_argument("--resume", type=str, default=None)
    parser.add_argument("--out", type=str, default="models/pooled")
    parser.add_argument("--rounds", type=int, default=None, help="stop after N rounds instead of running forever -- mainly for testing")
    parser.add_argument("--round-timeout", type=float, default=cfg.ROUND_TIMEOUT_SEC, help="override pool_config.ROUND_TIMEOUT_SEC -- mainly for fast local testing")
    parser.add_argument("--publish-weights", type=str, default=None,
                         help="also export the policy to this JSON path every checkpoint (same cadence as --out's .zip) -- "
                              "e.g. relay-server/data/ai_policy_weights.json, so GET /api/ai/policy-weights can serve "
                              "the live pool's current model to game clients. Omit to only checkpoint the .zip, same as before.")
    args = parser.parse_args()

    env = TagVecEnv(max(args.local_envs, 1))  # PPO._setup_learn() requires a real VecEnv even if local_envs contributes nothing

    # device="cpu" explicitly everywhere in this design (learner and
    # worker alike) -- MlpPolicy is fast enough on CPU that SB3 itself
    # warns against GPU for it, and it sidesteps ever having to reconcile
    # a GPU-trained state_dict against terraserver's (GPU-less) hardware
    # or a worker machine that may or may not have one.
    if args.resume:
        model = PPO.load(args.resume, env=env, device="cpu")
    else:
        model = PPO(
            "MlpPolicy", env, verbose=0, device="cpu",
            gamma=cfg.GAMMA, gae_lambda=cfg.GAE_LAMBDA, n_steps=cfg.N_STEPS, batch_size=cfg.BATCH_SIZE,
            policy_kwargs=cfg.POLICY_KWARGS,
        )

    # _setup_learn() does the bookkeeping model.learn() normally hides
    # (sets up self.logger, self._last_obs via env.reset(), etc.) --
    # PPO.train() crashes on its first logger.record() call without it.
    # total_timesteps is a sentinel only used for the (unused, since we
    # never pass a schedule) progress-remaining calculation -- this
    # process runs until --rounds or killed, not until a step count.
    _, callback = model._setup_learn(total_timesteps=10**15, callback=None, reset_num_timesteps=(args.resume is None))

    # install.sh's stop_proc() sends a plain SIGTERM -- Python's default
    # handling for that terminates the process immediately without
    # running try/finally blocks, which would silently skip the
    # final-checkpoint-on-shutdown safety net below on every ordinary
    # `install.sh stop tag-trainer`, not just an actual crash. Converting
    # it to SystemExit routes it through the same finally block a clean
    # Ctrl+C (SIGINT) already goes through.
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))

    state = LearnerState(model)
    server = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(f"learner listening on :{args.port} (local_envs={args.local_envs})")

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    round_num = 0
    try:
        while args.rounds is None or round_num < args.rounds:
            contributed = run_round(state, env, callback, args.local_envs, args.round_timeout)
            round_num += 1
            if contributed and round_num % cfg.CHECKPOINT_EVERY_N_ROUNDS == 0:
                model.save(args.out)
                print(f"checkpoint saved to {args.out}.zip")
                if args.publish_weights:
                    _publish_weights(model, args.publish_weights)
                    print(f"published weights to {args.publish_weights}")
    finally:
        model.save(args.out)
        print(f"final checkpoint saved to {args.out}.zip")
        if args.publish_weights:
            _publish_weights(model, args.publish_weights)
            print(f"published weights to {args.publish_weights}")
        server.shutdown()


if __name__ == "__main__":
    main()
