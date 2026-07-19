# Tag — Design Specification

## 1. Overview

Tag is a real-time multiplayer game built in Godot, implementing a
competitive hot-potato "tag" game mode with optional ranked matchmaking.
It consists of a game client, a dedicated headless game server, and a
Node.js relay/directory service that allows players to host and join
matches without port-forwarding or any network configuration on the
host's part.

## 2. Goals

- **Zero network configuration for hosts.** A player hosting a match
  should never need to configure port-forwarding, a static IP, or a
  personal tunnel. All host-to-relay and player-to-host traffic is
  bridged through a shared relay service.
- **Server-authoritative gameplay.** All decisions that affect fairness —
  who is "it," collision outcomes, ranked match results — are decided by
  the dedicated server, never trusted from a client.
- **Never hard-fail on user content.** Custom maps and cosmetics are
  published directly by players with no manual review step. Any failure
  to fetch, parse, or validate custom content must degrade to a safe
  default rather than preventing a match from starting.
- **Self-updating clients.** Both the game client and the standalone art
  tool should be able to detect and install their own updates without
  requiring users to manually redownload and reinstall.

## 3. System Architecture

```
   Game Client A ──┐                          ┌── Game Client B
                    │                          │
                    ▼                          ▼
              Relay-server (directory + NAT-traversal-free bridge)
                    ▲                          ▲
                    │                          │
              Dedicated Game Server (hosted by a player)
```

Three distinct processes are involved in a hosted match:

1. **Dedicated game server** — a headless instance of the game itself,
   launched locally by whichever player is hosting.
2. **Relay-server** — a persistent Node.js service that the dedicated
   server registers with, and through which remote players connect.
3. **Game clients** — the players, including the host's own client if
   they are also playing.

### 3.1 Relay bridging protocol

The dedicated server maintains one long-lived "control" connection to the
relay, over which it registers itself, sends periodic heartbeats, and
receives connection requests. For each incoming player, a second,
dedicated bridge connection is opened between the relay and the
dedicated server, and packets are forwarded byte-for-byte in both
directions between that bridge connection and the dedicated server's own
loopback multiplayer listener. The relay and this bridge are not aware
of the game protocol being carried — they move opaque bytes. A server
whose heartbeat lapses is removed from the public directory
automatically; there is no explicit "unregister" step relied upon for
correctness, since a crashed or killed host will never send one.

## 4. Gameplay Rules

### 4.1 Core loop

One participant is designated "it" at any time. Proximity between "it"
and any other participant beyond a short immunity window transfers the
"it" status to that participant. Participants that remain in continuous
physical contact beyond a fixed threshold are automatically separated,
preventing a degenerate state where two participants repeatedly retag
each other the instant immunity expires because they never physically
separated.

### 4.2 Ranked matches

A ranked round runs for a fixed duration and tracks, per participant, the
cumulative time spent as "it." At the end of the round, participants are
placed by that accumulated time (least time as "it" is the best
placement), and this placement feeds into a rating update.

### 4.3 Rating system

Ratings use an Elo-family algorithm extended to support matches with more
than two participants: every pair of participants in the match is
treated as an independent virtual head-to-head result, with the better-
placed participant of each pair counted as the winner of that pair. Each
participant's total rating change is the average of their expected-versus-
actual outcome across every such pair, which keeps the magnitude of
rating movement comparable regardless of how many participants were in
the match — a large lobby should not swing ratings substantially more
than a small one.

| Tier | Minimum rating |
|---|---|
| Bronze | 0 |
| Silver | 1100 |
| Gold | 1300 |
| Platinum | 1550 |
| Diamond | 1850 |

Tier boundaries are duplicated on both the client (for immediate local
badge rendering without a round trip) and the relay-server (as the
authoritative source), and must be kept in sync by hand when changed.

## 5. Content Systems

### 5.1 Cosmetics

Players may draw and publish custom character skins and hats directly
from an in-game editor or the standalone art tool. Published content is
live immediately, with no manual review — a deliberate trust model
appropriate for a small, closed player base rather than a public
platform. Published cosmetics are pulled by other clients the next time
they open the relevant selection screen.

### 5.2 Custom levels

Levels are represented as a minimal, data-only format — a list of tile
placements and spawn points, containing no executable content or asset
references beyond tile indices into the game's existing, built-in
tileset. A dedicated server hosting a custom level fetches this data from
the relay at match start and constructs the playable arena from it at
runtime. Any failure at any stage of that process — network failure,
malformed data, failing validation — falls back transparently to the
game's default arena, so a bad or unreachable custom level can never
prevent a host from starting a match.

### 5.3 In-editor tooling

A standalone art tool application provides sprite drawing, level editing,
and direct publishing to the relay-server, intended for players without
a Godot development environment.

## 6. Update Distribution

Both the game client and the standalone art tool check the project's
release feed on startup, compare against their own embedded build number,
and offer an in-place update if a newer build is available. Accepting an
update downloads the new executable, hands off to a small helper process
that waits for the running application to exit before replacing it and
relaunching — necessary because a running executable cannot overwrite
its own file directly on the target platform. Dedicated server processes
skip this check entirely, since there is no interactive user present to
respond to an update prompt.

## 7. Deployment

The relay-server component is one of the applications managed by the
shared `install.sh` installer described in the top-level project's
`DESIGN_SPEC.md`; the game client and dedicated server executables are
built and distributed independently through the project's own continuous
integration pipeline, not through that installer.
