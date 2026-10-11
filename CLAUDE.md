# dot-match

The match loop: warmup, countdown, rounds, intermission, scoring, teams and autobalance, respawns and spawn selection, a kill feed, and the replicated clock. One call advances it, and everything is counted in ticks.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to matches.

**The distributable is `addons/dot_match/`.** It requires [dot-core](../dot-core) and nothing else (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored). Games bind it to dot-server, dot-net and dot-combat through callables and their own module.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: ticks, rules vs config, tie-breaks, kills, respawns, autobalance, spawn selection, the clock, coupling, what is not here |
| [docs/history.md](docs/history.md) | touching the state machine or spawn points: the stuck `COUNTDOWN`, the array cleared by reference |

## Layout

| Path | What |
| --- | --- |
| `dot_match.gd` | `DotMatch`: the state machine, `tick()`, `report_kill` / `report_assist` / `report_objective`, spawn points, `position_fn` |
| `dot_match_config.gd` | `DotMatchConfig`: how the server runs it (`balance_between_rounds`) |
| `rules/` | `DotMatchRules` (what the mode is: limits, `min_players`, `pause_when_empty`), `DotRulesElimination` (`alive_fn`) |
| `core/` | `DotScoreboard`, `DotPlayerScore`, `DotTeam`, `DotTeamManager` (assignment, `rebalance`, `team_lookup()`), `DotRespawnQueue`, `DotKillFeed` |
| `spawn/` | `DotSpawnPoint`, `DotSpawnSelector` (cooldowns, threats, `_fallback`) |
| `net/dot_match_net_sync.gd` | `DotMatchNetSync`: state and `net_ends_at` as data specs |
| `examples/match_selftest.tscn` | the suite, offline |

Paths except `examples/` are in `addons/dot_match/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `godot --headless --path . res://examples/match_selftest.tscn` (exits non-zero on any failure). Run it after any change to the state machine: its bugs parse cleanly.

## Rules that bite

- `DotMatch.tick(current_tick)` is the only thing that advances a match; no `Timer`, `_process` or wall clock. [design](docs/design.md#one-call-moves-the-match-and-everything-is-counted-in-ticks)
- A threshold and the decision about it live on the same object; what the mode is goes on `DotMatchRules`. [design](docs/design.md#dotmatchrules-is-what-the-mode-is-dotmatchconfig-is-how-the-server-runs-it)
- Every ordering has an explicit tie-break; never iterate a dictionary to decide. A tie-break on a StringName (`Node.name`, an id) compares `String(…)`: StringNames compare by interning. [design](docs/design.md#ordering-is-never-left-to-a-dictionary)
- All deaths go through `report_kill` (empty killer = world, equal = suicide); outside `LIVE` it scores nothing. [design](docs/design.md#kills-go-through-one-method)
- `report_kill` can end the round synchronously; re-check `is_live()` after it. [design](docs/design.md#kills-go-through-one-method)
- Ending a round clears the respawn queue. [design](docs/design.md#ending-a-round-clears-the-respawn-queue)
- Autobalance only between rounds, with a grace period, bounded, moving the longest-serving player. [design](docs/design.md#autobalance-runs-between-rounds-not-during-them)
- Spawn selection falls back rather than refusing; threats are enemies only. [design](docs/design.md#spawn-selection-gives-up-gracefully)
- Change spawn points only through `add_` / `remove_` / `clear_spawn_points`; never mutate the array `spawn_points()` returns. [design](docs/design.md#spawn-selection-gives-up-gracefully)
- Replicate the absolute end tick; `seconds_remaining` is -1 for no clock on both sides. [design](docs/design.md#the-replicated-clock-is-an-absolute-end-tick)
- Name no class outside dot-core; nothing here spawns anything. [design](docs/design.md#coupling-nothing-is-imported)

Deliberately not here: objectives (dot-objective), map rotation and votes (dot-map, dot-vote), assist attribution, persisted stats, a HUD. [design](docs/design.md#deliberately-not-here)
