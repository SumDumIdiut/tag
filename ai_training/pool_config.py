"""
Hyperparameters shared by learner.py and worker.py (distributed/pooled
training -- see ai_training/README.md). Every value here that feeds
RolloutBuffer.compute_returns_and_advantage() (GAMMA, GAE_LAMBDA, N_STEPS)
or the policy's architecture (NET_ARCH) MUST be identical on every
contributing machine: each machine computes its own GAE independently
before the learner concatenates the finished arrays, so two machines
computing GAE under different gamma/lambda would silently pool
mathematically-inconsistent advantages into one gradient step -- no
crash, just quietly wrong training. Importing this one module from both
ends is what prevents that drift, instead of each file hand-typing its
own copy of these numbers.
"""

GAMMA = 0.99
GAE_LAMBDA = 0.95
NET_ARCH = [64, 64]  # matches trained_policy.gd's hand-written forward pass shape
POLICY_KWARGS = {"net_arch": NET_ARCH}

# Transitions collected per env, per round, on every contributing machine
# alike -- fixed (not derived from how many workers happen to be
# connected), since concatenating buffers from different machines along
# the env axis requires them to all share the same time axis length.
N_STEPS = 32

# PPO minibatch size for the learner's train() call against the pooled
# buffer. Not used by worker.py at all (workers only ever call
# collect_rollouts(), never train()).
BATCH_SIZE = 512

# How long the learner waits for worker /contribute submissions tagged
# with the currently-open round before closing it and training on
# whatever arrived (learner's own local contribution, if any, always
# counts -- this is a ceiling on stragglers, not a required quorum).
ROUND_TIMEOUT_SEC = 30.0

# How often (in learner rounds, not worker rounds) the learner writes a
# checkpoint. Deliberately not routed through SB3's CheckpointCallback --
# that callback only fires from inside collect_rollouts()'s own loop,
# which this design bypasses entirely (the learner calls model.train()
# directly against a manually-pooled buffer) -- routing through it would
# silently checkpoint nothing, ever.
CHECKPOINT_EVERY_N_ROUNDS = 25

# The exact 6 RolloutBuffer arrays PPO.train() actually reads (confirmed
# by reading buffers.py's RolloutBuffer.get()/_get_samples() directly --
# `rewards`/`episode_starts` are consumed only inside
# compute_returns_and_advantage() and never touched again). Each
# contributor runs compute_returns_and_advantage() locally before
# submitting, so only these 6 ever need to cross the network.
POOLED_ARRAY_NAMES = ("observations", "actions", "values", "log_probs", "advantages", "returns")
