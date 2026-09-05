This is the **match** asset for TMC's **Dot** collection. It is the loop a session actually runs on, counted in ticks so the round clock and the netcode agree about what time it is.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## The Match Loop
The match loop for a Godot 4 multiplayer game: warmup, rounds, scoring, teams,
spawning and respawning. Everything counted in ticks and driven by one call, so a
server's round clock and its netcode agree about what time it is.

Part of the [dot-*](../NOTES.md) family. Needs **dot-core** and nothing else.

## Install

Copy `addons/dot_match/` and `addons/dot_core/` into your project and enable both in
*Project → Project Settings → Plugins*.

## Use

```gdscript
var match_node := DotMatch.new()
match_node.rules = DotMatchRules.deathmatch(30)
match_node.position_fn = func(key): return player_position(key)
add_child(match_node)

match_node.respawn_due.connect(func(key, spawn, tick):
    spawn_player(key, spawn.spawn_transform())
)

# Once per simulated tick, on the server.
match_node.tick(tick)

# When someone dies.
match_node.report_kill(killer_key, victim_key, &"rifle", tick, headshot)
```

## The idea

A match is a state machine — `WARMUP → COUNTDOWN → LIVE → INTERMISSION → MATCH_END` —
and **one call moves it**. No `Timer`, no `_process`, no wall clock.

A match that ticks itself ticks on whatever schedule the engine gives it, which is not
the schedule the simulation runs on. A server whose round timer and whose netcode
disagree about what time it is produces a round that ends on a different tick for every
client.

What *winning* means lives in a `DotMatchRules` resource. `DotMatch` never asks what
mode it is running.

## What is in the box

| | |
| --- | --- |
| `DotMatch` | The state machine. Rounds, clocks, respawns, and the win check. |
| `DotMatchRules` | What winning means and what a kill is worth. Subclass for a new mode. |
| `DotRulesElimination` | A worked subclass: the round ends when one side is wiped. |
| `DotScoreboard` / `DotPlayerScore` | Who is playing and how they are doing. Survives reconnects. |
| `DotTeam` / `DotTeamManager` | Sides, assignment, and deterministic autobalance. |
| `DotKillFeed` | The last few kills, as data rather than as formatted strings. |
| `DotSpawnPoint` / `DotSpawnSelector` | Where a player appears, and why that one. |
| `DotRespawnQueue` | Who is waiting to come back, counted against a target tick. |
| `DotMatchNetSync` | What to replicate, without naming a dot-net type. |

## Three failure modes it is built around

**A scoreboard that rewards rage-quitting.** Records survive a disconnection and a
reconnecting player gets their kills back. They are keyed by a stable player key, never
a peer id — a peer id is reassigned the moment someone reconnects, and a scoreboard
keyed by one hands the next player to join the previous player's kills.

**Two machines that disagree.** Every ordering decision has an explicit tie-break:
ranked scoreboards fall back to the player key, spawn selection to the node name, team
assignment to the lower team id, respawn batches to a sort. Left to dictionary
iteration order, a server and a client produce different answers — and for team
assignment that means they disagree about friendly fire.

**A round that never ends.** `DotRulesElimination` treats *zero* teams standing as the
end of the round, not as "keep going". A grenade that kills the last player on both
sides happens often enough to matter, and waiting for a side that no longer exists is a
server that has to be restarted.

## Spawning

The default rule is furthest-from-the-nearest-threat among the available points, and
threats are **enemies only** — spawning people away from their own team scatters a
squad across the map. Points have a cooldown, which is what stops two players spawning
inside each other.

When every point is on cooldown or occupied, the selector falls back and spawns someone
anyway. **Spawning badly beats not spawning at all**: the alternative is a player who
is dead until a point frees up, which on a busy map with a short round is the rest of
the match.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/match_selftest.tscn
```

114 checks, all offline. Exits non-zero on any failure.
