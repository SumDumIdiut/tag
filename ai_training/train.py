#!/usr/bin/env python3
"""
CLI to train a Tag-playing PPO agent against a scripted opponent, using the
fast NumPy simulator in sim.py/tag_env.py (no Godot, no rendering -- see
sim.py's own docstring for why this can run far faster than real-time).

Usage:
    python train.py --games 100000
    python train.py --games 5000 --envs 256 --out models/quick_test
    python train.py --resume models/quick_test.zip --games 20000

"--games" is converted to PPO training timesteps as games * average-steps-
per-game (estimated from ROUND_DURATION_SEC * 60Hz, i.e. one game = one
full round unless it ends early -- it never does here, rounds always run
the full clock). Run this as many times as you like (each run either
starts fresh or --resume's a saved model) -- this is the actual "run it
several times" CLI, not a single one-shot training call.
"""

import argparse
import os

from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import CheckpointCallback

from sim import ROUND_DURATION_SEC, TICK_DT
from tag_env import TagVecEnv

STEPS_PER_GAME = int(ROUND_DURATION_SEC / TICK_DT)  # 10800 at 60Hz/180s


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--games", type=int, default=1000, help="how many full rounds' worth of experience to train on this run")
    parser.add_argument("--envs", type=int, default=128, help="parallel simulated matches per training step -- higher uses more RAM/CPU but trains faster wall-clock")
    parser.add_argument("--out", type=str, default="models/tag_ppo", help="where to save the trained model (.zip appended automatically)")
    parser.add_argument("--resume", type=str, default=None, help="path to an existing .zip to continue training instead of starting fresh")
    parser.add_argument("--checkpoint-every", type=int, default=50_000, help="save an intermediate checkpoint every N timesteps, in case a long run gets interrupted")
    args = parser.parse_args()

    total_timesteps = args.games * STEPS_PER_GAME
    print(f"Training on ~{args.games} games ({total_timesteps:,} timesteps) across {args.envs} parallel matches...")

    env = TagVecEnv(args.envs)

    if args.resume:
        print(f"Resuming from {args.resume}")
        model = PPO.load(args.resume, env=env)
    else:
        model = PPO(
            "MlpPolicy",
            env,
            verbose=1,
            n_steps=2048 // args.envs if args.envs < 2048 else 1,
            batch_size=min(4096, args.envs * 8),
            policy_kwargs={"net_arch": [64, 64]},  # small on purpose -- see export_weights.py, this needs to run as a plain GDScript forward pass eventually
        )

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    callback = CheckpointCallback(
        save_freq=max(args.checkpoint_every // args.envs, 1),
        save_path=os.path.dirname(args.out) or ".",
        name_prefix=os.path.basename(args.out) + "_ckpt",
    )

    model.learn(total_timesteps=total_timesteps, callback=callback, reset_num_timesteps=args.resume is None)
    model.save(args.out)
    print(f"Saved trained model to {args.out}.zip")
    print(f"Run again with --resume {args.out}.zip --games <more> to keep training this same model.")


if __name__ == "__main__":
    main()
