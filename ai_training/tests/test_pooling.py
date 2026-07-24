#!/usr/bin/env python3
"""
Correctness checks for the distributed training pool (pooling.py,
learner.py, worker.py). Plain script, not pytest (no test framework in
requirements.txt, and this is a local dev-time check, not part of CI) --
run directly:

    python tests/test_pooling.py

Each test function is self-contained and raises AssertionError on
failure; main() runs them all and reports pass/fail, exiting non-zero if
anything failed.
"""

from __future__ import annotations

import http.server
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

import numpy as np
import torch as th

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import learner as learner_mod  # noqa: E402
import pool_config as cfg  # noqa: E402
import pooling  # noqa: E402
from stable_baselines3 import PPO  # noqa: E402
from tag_env import TagVecEnv  # noqa: E402


def _make_model(num_envs: int):
    env = TagVecEnv(num_envs)
    model = PPO(
        "MlpPolicy", env, verbose=0, device="cpu",
        gamma=cfg.GAMMA, gae_lambda=cfg.GAE_LAMBDA, n_steps=cfg.N_STEPS, batch_size=cfg.BATCH_SIZE,
        policy_kwargs=cfg.POLICY_KWARGS,
    )
    _, callback = model._setup_learn(total_timesteps=10**6, callback=None, reset_num_timesteps=True)
    return env, model, callback


def _get(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=10) as resp:
        return resp.read()


def _post(url: str, data: bytes) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


# ─── Unit-level: pool_rollouts() itself, no network involved ───────────────────

def test_pool_rollouts_preserves_columns():
    env_a, model_a, cb_a = _make_model(4)
    env_b, model_b, cb_b = _make_model(6)
    model_b.policy.load_state_dict(model_a.policy.state_dict())  # same weights -- a fair "two contributors, same round"

    roll_a = pooling.collect_local_rollout(model_a, env_a, cb_a, n_steps=cfg.N_STEPS)
    roll_b = pooling.collect_local_rollout(model_b, env_b, cb_b, n_steps=cfg.N_STEPS)

    pooled = pooling.pool_rollouts(
        [{k: roll_a[k] for k in cfg.POOLED_ARRAY_NAMES}, {k: roll_b[k] for k in cfg.POOLED_ARRAY_NAMES}],
        model_a.observation_space, model_a.action_space, "cpu",
    )
    assert pooled.full is True
    assert pooled.observations.shape[1] == 10  # 4 + 6
    for name in cfg.POOLED_ARRAY_NAMES:
        np.testing.assert_array_equal(getattr(pooled, name)[:, :4], roll_a[name])
        np.testing.assert_array_equal(getattr(pooled, name)[:, 4:], roll_b[name])
    assert not np.isnan(pooled.advantages).any()
    assert not np.isnan(pooled.returns).any()


def test_returns_equals_advantages_plus_values():
    env, model, cb = _make_model(4)
    roll = pooling.collect_local_rollout(model, env, cb, n_steps=cfg.N_STEPS)
    np.testing.assert_allclose(roll["returns"], roll["advantages"] + roll["values"], atol=1e-4)


def test_serialize_roundtrip():
    env, model, cb = _make_model(4)
    roll = pooling.collect_local_rollout(model, env, cb, n_steps=cfg.N_STEPS)
    payload = pooling.serialize_contribution(roll)
    restored = pooling.deserialize_arrays(payload)
    assert set(restored.keys()) == set(cfg.POOLED_ARRAY_NAMES)
    for name in cfg.POOLED_ARRAY_NAMES:
        np.testing.assert_array_equal(restored[name], roll[name])


def test_weights_roundtrip():
    _, model, _ = _make_model(2)
    sd = model.policy.state_dict()
    payload = pooling.serialize_weights(sd)
    restored = pooling.deserialize_weights(payload)
    assert set(restored.keys()) == set(sd.keys())
    for name, tensor in sd.items():
        assert th.equal(restored[name], tensor.cpu())


# ─── Integration-level: real HTTP over a real socket ────────────────────────────

def test_integration_round_lifecycle():
    port = 8781
    env, model, callback = _make_model(4)  # the "learner"'s own local envs
    state = learner_mod.LearnerState(model)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), learner_mod.make_handler(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{port}"

    try:
        # Round 1: nobody else contributes -- must still close via timeout
        # using just the local envs, not hang waiting for a worker that
        # never shows up.
        t0 = time.monotonic()
        contributed_1 = learner_mod.run_round(state, env, callback, local_envs=4, round_timeout_sec=1.5)
        elapsed = time.monotonic() - t0
        assert contributed_1 == 4, f"expected only the 4 local envs, got {contributed_1}"
        assert elapsed < 5.0, f"round took {elapsed:.1f}s -- looks like it hung instead of timing out"
        weights_round_1 = _get(f"{base}/weights")
        params_before = {k: v.clone() for k, v in model.policy.state_dict().items()}

        # Round 2: run it in a background thread, and once its round_id
        # has actually opened, have a hand-rolled "worker" (same code
        # pooling.collect_local_rollout/serialize_contribution real
        # worker.py uses, just driven directly instead of via a
        # subprocess) fetch weights and contribute over real HTTP before
        # the round's timeout elapses.
        result: dict = {}

        def _run_round_2():
            result["contributed"] = learner_mod.run_round(state, env, callback, local_envs=4, round_timeout_sec=3.0)

        round_thread = threading.Thread(target=_run_round_2)
        round_thread.start()

        deadline = time.monotonic() + 5.0
        while state.round_id != 2 and time.monotonic() < deadline:
            time.sleep(0.05)
        assert state.round_id == 2, "round 2 never opened"

        worker_id = "test-worker-1"
        info = json.loads(_get(f"{base}/round?worker_id={worker_id}"))
        assert info["round_id"] == 2
        worker_env, worker_model, worker_cb = _make_model(6)
        worker_model.policy.load_state_dict(pooling.deserialize_weights(_get(f"{base}/weights")))
        worker_roll = pooling.collect_local_rollout(worker_model, worker_env, worker_cb, n_steps=info["n_steps"])
        status, body = _post(
            f"{base}/contribute?round_id={info['round_id']}&worker_id={worker_id}",
            pooling.serialize_contribution(worker_roll),
        )
        assert status == 200, f"contribute should have been accepted: {body}"

        round_thread.join(timeout=10)
        assert "contributed" in result, "round 2 never finished"
        assert result["contributed"] == 10, f"expected 4 local + 6 worker envs, got {result['contributed']}"

        weights_round_2 = _get(f"{base}/weights")
        assert weights_round_1 != weights_round_2, "weights should differ after a real gradient step"
        params_after = model.policy.state_dict()
        assert any(not th.equal(params_before[k], params_after[k]) for k in params_before), \
            "expected at least one policy tensor to change after train()"

        # A submission tagged with round 1's (now closed) id must be
        # rejected, not silently pooled into round 2's already-finished data.
        stale_payload = pooling.serialize_contribution(worker_roll)
        status, body = _post(f"{base}/contribute?round_id=1&worker_id={worker_id}", stale_payload)
        assert status == 409, f"expected 409 for a stale round_id, got {status}: {body!r}"

    finally:
        server.shutdown()


def test_dedicate_flag_reflected_in_status():
    port = 8782
    env, model, callback = _make_model(2)
    state = learner_mod.LearnerState(model)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), learner_mod.make_handler(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{port}"
    try:
        worker_id = "toggle-test-worker"
        info = json.loads(_get(f"{base}/round?worker_id={worker_id}"))
        assert info["dedicate"] is False, "an unseen worker_id should default to dedicate=off"

        status, _ = _post(f"{base}/dedicate?worker_id={worker_id}&on=true", b"")
        assert status == 200
        info = json.loads(_get(f"{base}/round?worker_id={worker_id}"))
        assert info["dedicate"] is True

        status, _ = _post(f"{base}/dedicate?worker_id={worker_id}&on=false", b"")
        assert status == 200
        info = json.loads(_get(f"{base}/round?worker_id={worker_id}"))
        assert info["dedicate"] is False
    finally:
        server.shutdown()


def main() -> int:
    tests = [
        test_pool_rollouts_preserves_columns,
        test_returns_equals_advantages_plus_values,
        test_serialize_roundtrip,
        test_weights_roundtrip,
        test_integration_round_lifecycle,
        test_dedicate_flag_reflected_in_status,
    ]
    failures = []
    for test in tests:
        print(f"{test.__name__} ... ", end="", flush=True)
        try:
            test()
            print("PASS")
        except Exception as exc:
            print(f"FAIL: {exc}")
            failures.append(test.__name__)
    print()
    if failures:
        print(f"{len(failures)}/{len(tests)} FAILED: {', '.join(failures)}")
        return 1
    print(f"all {len(tests)} tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
