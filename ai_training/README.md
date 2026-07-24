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

## What's NOT done yet

This is the training pipeline itself -- real, runnable, produces an
actually-trained model. **Not yet built**: loading a trained model's
weights back into the real game so it controls an actual NPC in Godot.
`export_weights.py` dumps a trained policy to plain JSON specifically so a
small GDScript forward pass (a couple Dense+tanh layers, cheap to run) can
consume it, but that GDScript inference code doesn't exist yet -- wiring a
trained policy into `game/npc/npc.gd` as a selectable "AI-trained" bot
difficulty is the natural next step once a model's actually been trained
and its behavior checked.
