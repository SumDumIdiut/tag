# Tag AI training

A from-scratch RL training pipeline for a Tag-playing bot, trained against
a scripted opponent via PPO (self-play against a second copy of the
trained policy is a reasonable next step once this baseline works, not
implemented here yet).

## Why this exists, not Godot itself

Godot (even headless, even with `Engine.time_scale` pushed up) still pays
real per-frame engine overhead every physics tick. `sim.py` is a from-
scratch NumPy re-implementation of the game's core physics and tag rules
(same constants as `game/player/player.gd`/`game/modes/tag_mode.gd`,
mirrored by hand -- see `sim.py`'s own header) that simulates many parallel
matches as batched array ops with zero engine overhead, which is what
actually gets training to run at far faster than real-time.

**Scope, deliberately**: run/jump/dash/gravity, real platform collision, and
the real tag/immunity rules -- not wall-jumping, climbing, or corner-
correction. `game/npc/npc.gd`'s own existing bot AI never uses any of those
three either (it only ever sets move_dir/jump/dash), so this simulator's
action space already covers everything a Tag bot actually needs to decide.

**Trains across every map in the online pool**, not one fixed arena --
`sim.py`'s `MAP_PLATFORMS` holds all 8 real maps' platform rects (7 copied
straight from `game/levels/online_maps/catalog.gd` /
`game/levels/local_maps/catalog.gd`, `classic_arena` extracted from its
TileMapLayer via `game/tools/extract_arena_rects.gd` since it has no simple
rect list). `TagSim.reset()` picks a random arena per resetting env
(domain randomization), so a trained model sees a real mix of layouts
instead of overfitting to one. Falling through one of the few maps' real
gaps (Staircase, Scattered Islands) respawns the agent back to a random
spawn on the same arena instead of diverging (`_respawn_fallen()`) --
mirrors a real, still-open bug in the actual game itself (neither
`player.gd` nor `server_match.gd` has any fall-recovery either).

## Setup

```
pip install -r requirements.txt
```

## Train

```
python train.py --games 100000
```

Runnable repeatedly -- each call either starts a fresh model or continues
one via `--resume`:

```
python train.py --games 50000 --out models/my_bot
python train.py --resume models/my_bot.zip --games 50000   # keep training the same model
```

`--envs` controls how many matches run in parallel per training step
(default 128) -- higher uses more RAM/CPU but trains faster wall-clock.

## Using a trained model in-game

```
python export_weights.py models/my_bot.zip --out ../game/assets/ai/npc_policy_weights.json
```

`game/npc/trained_policy.gd` loads that JSON and runs the forward pass
in plain GDScript (Godot has no built-in ONNX/PyTorch runtime -- see that
file's own header). `game/npc/npc.gd` calls it when an NPC has
`use_trained_policy = true`, then layers the existing scripted AI's own
skill-level formulas (`_mistake_chance()`/`_dash_chance()`) on top of the
network's raw decision, so the trained bot still respects Local's NPC
skill slider instead of always playing at full strength.

**Currently wired to a temporary toggle only**: Local's settings panel has
an "AI (trained): OFF" button (`game/main/local_menu.gd`) that sets
`GameSettings.use_trained_ai`, which `game/main/game.gd` uses to flag just
the first spawned NPC. This exists purely so the trained policy is
reachable for testing -- it isn't a real difficulty tier and nothing in
ranked/matchmaking reads it.

**`ARENA_HALF_EXTENT` must match exactly** between `tag_env.py` (what
observations were actually normalized by during training) and
`trained_policy.gd` (what they're normalized by at inference time) -- a
mismatch doesn't error, it just quietly feeds the network inputs scaled
differently than what it learned on. This was bumped from `(600, 650)` to
`(1250, 550)` when training went multi-arena (classic_arena and staircase
need the wider bound); the bundled `game/assets/ai/npc_policy_weights.json`
was trained under the *old* scale and needs re-exporting once a model's
been (re)trained against the current `sim.py`/`tag_env.py`.

## Resuming training

```
python train.py --resume models/npc_v1.zip --games 50000
```

`models/npc_v1.zip` is the current baseline (~3000 games / 32.4M steps,
trained back when `sim.py` only simulated `square_arena`) -- resuming
against today's multi-arena `sim.py` continues from those learned
run/jump/dash fundamentals while extending them to the other 7 maps, not a
from-scratch restart.

## Pooled training (multiple machines training one model together)

`learner.py`/`worker.py` let more than one machine contribute rollout
experience to the *same* PPO model, instead of each running its own
independent `train.py`. This reuses stable-baselines3's own
`collect_rollouts()`/`train()` unmodified -- each machine runs rollout
collection (and GAE) locally, a central learner concatenates the finished
per-env-column arrays from every contributor into one buffer each round,
and calls `train()` once against the pooled data. See `pool_config.py`
for the shared hyperparameters every contributor must agree on.

```
# one machine: the learner (holds the model + optimizer state)
python learner.py --port 8770 --local-envs 4 --resume models/npc_v1.zip --out models/pooled

# any other machine on the same LAN: a worker (pure rollout collection, no training)
python worker.py --learner http://<learner-host>:8770 --envs 256
```

A worker defaults to idle (polling only, near-zero CPU) until told to
dedicate:

```
curl -X POST "http://<learner-host>:8770/dedicate?worker_id=<id>&on=true"
```

(`worker_id` is generated once per machine and cached in `.worker_id`
next to `worker.py` -- printed to stdout on startup.) LAN-only by design,
no auth -- this is meant to run on a home network between machines you
already trust, not to be exposed publicly.

Currently local-only (a learner + worker can run on any two machines on
the LAN today) -- not yet wired up as a persistent terraserver service or
exposed via a dev-panel toggle; see `tests/test_pooling.py` for the
correctness checks (`python tests/test_pooling.py`) covering the pooling
math, the wire format, and the round/timeout/stale-rejection protocol.
