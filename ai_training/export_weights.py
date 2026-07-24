#!/usr/bin/env python3
"""
Dumps a trained PPO model's policy network to a plain JSON file of layer
weights/biases -- Godot has no built-in ONNX/PyTorch runtime, so the
intended consumer is a small hand-written matrix-multiply forward pass in
GDScript (NOT written yet -- see the project's own notes on this; wiring a
trained policy into game/npc/npc.gd as an actual in-game opponent is the
next step after a model exists, not part of this export step).

The policy is deliberately kept small (net_arch=[64,64], see train.py) so a
GDScript forward pass is cheap: obs(14) -> Dense(64,tanh) -> Dense(64,tanh)
-> action logits, split into the three MultiDiscrete heads (move:3,
jump:2, dash:2).

Usage:
    python export_weights.py models/tag_ppo.zip --out models/tag_ppo_weights.json
"""

import argparse
import json

import numpy as np
from stable_baselines3 import PPO


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model_path", type=str, help="trained model .zip from train.py")
    parser.add_argument("--out", type=str, default=None, help="output JSON path (defaults to <model_path without .zip>_weights.json)")
    args = parser.parse_args()

    out_path = args.out or args.model_path.replace(".zip", "") + "_weights.json"

    model = PPO.load(args.model_path)
    policy = model.policy

    layers = []
    # SB3's default MlpExtractor policy net -- mlp_extractor.policy_net is
    # the shared trunk, action_net is the final linear layer to logits.
    for layer in policy.mlp_extractor.policy_net:
        if hasattr(layer, "weight"):
            layers.append({
                "weight": layer.weight.detach().cpu().numpy().tolist(),
                "bias": layer.bias.detach().cpu().numpy().tolist(),
                "activation": "tanh",
            })
    layers.append({
        "weight": policy.action_net.weight.detach().cpu().numpy().tolist(),
        "bias": policy.action_net.bias.detach().cpu().numpy().tolist(),
        "activation": "none",
    })

    # MultiDiscrete([3, 2, 2]) action logits are concatenated in that order
    # in the final layer's output -- these split points let a GDScript
    # consumer slice them back apart.
    action_dims = [3, 2, 2]

    with open(out_path, "w") as f:
        json.dump({"layers": layers, "action_dims": action_dims}, f)
    print(f"Exported {len(layers)} layers to {out_path}")


if __name__ == "__main__":
    main()
