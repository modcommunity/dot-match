# dot-match

The match loop. Read `../../CLAUDE.md` first for the family-wide rules; this file is
only what is specific to matches.

## The one idea

**One call moves the match, and everything is counted in ticks.**

`DotMatch.tick(current_tick)` is the only thing that advances anything. There is no
`Timer`, no `_process`, no `Time.get_ticks_msec`. A match that ticks itself ticks on
whatever schedule the engine gives it, which is not the schedule the simulation runs
on — and a server whose round clock and whose netcode disagree about what time it is
produces a round that ends on a different tick for every client.

The corollary is that a match is testable without a frame ever being rendered, which is
why this project's self-test can run a two-round series in a few hundred synchronous
calls.

## `DotMatchRules` is what the mode is; `DotMatchConfig` is how the server runs it

Swapping the rules changes the game. Changing the config does not. That split is why
`min_players` and `pause_when_empty` are both on the *rules*: a threshold in one file
and the decision about what to do at it in another is exactly the split that produced
the bug the self-test found — `pause_when_empty` was read off the config and declared
on the rules, and the match sat in `COUNTDOWN` forever.

`DotMatchConfig` used to carry a `run_when_empty` that overlapped `pause_when_empty`
and that nothing read. Two settings that mean nearly the same thing are worse than
either alone.

## Ordering is never left to a dictionary

Every place two things could be equal has an explicit tie-break:

| Decision | Tie-break | Why |
| --- | --- | --- |
| `DotScoreboard.ranked` | player key | Otherwise players visibly swap places on a client |
| `DotSpawnSelector.choose` | node name | A symmetric map ties on nearly every point |
| `DotTeamManager.smallest_team` | lower team id | Server and client must agree who is on which side |
| `DotTeamManager._balance_candidate` | player key | Two machines must move the same person |
| `DotRespawnQueue.take_ready` | sorted keys | Decides who gets the good spawn when several return together |
| `DotScoreboard.leading_team` | lower team id | Same reason as assignment |

Team assignment is the one where the consequence is not cosmetic: a server and a client
that disagree about someone's team disagree about friendly fire, which is a player who
cannot damage the enemy and can damage their own side.

## Kills go through one method, and it handles the ugly cases

`report_kill` takes an empty `killer_key` for a world death and an equal one for a
suicide. Both go through it rather than through separate methods, because every caller
would otherwise have to work out which case it is, and the one that gets it wrong
credits a kill to nobody. `DotKillFeed.add_kill` accepts a null killer for the same
reason — "killed by someone who has already disconnected" is a normal event and a null
dereference if it is not handled centrally.

**A kill outside `LIVE` records the death and scores nothing**, and does not re-run the
win check. Both halves matter: a kill during warmup would let the first player to
connect farm the second one before the match starts, and a kill during intermission —
a rocket already in the air when the round ended — would re-run a win check on a round
that is over.

## Ending a round clears the respawn queue

A player who died on the round-winning kill must not reappear during the intermission.
The self-test asserts exactly two respawns across three kills for this reason, and the
comment says so, because "3 kills, 2 respawns" reads as an off-by-one otherwise.

## Autobalance runs between rounds, not during them

`DotMatchConfig.balance_between_rounds` calls it at round start. Switching someone
mid-fight takes a player who was winning a duel and puts them on the other side of it.

`balance_grace_ticks` is the second half: being switched immediately after switching is
the single most annoying thing an autobalancer does, and two joins in a row can produce
it. `rebalance` is bounded rather than `while not is_balanced()` — a team at
`max_players` with everyone inside their grace period is permanently unbalanceable, and
a loop that assumed otherwise would hang the server between rounds.

`_balance_candidate` picks the **longest-serving** player on the oversized team, not
the newest. The newest arrival is the one most likely to have just been assigned there,
and moving them immediately is the case the grace period exists to prevent.

## Spawn selection is allowed to give up gracefully

`DotSpawnSelector._fallback` runs when every point is on cooldown, occupied, or tagged
for another team. It spawns someone anyway, ignoring all of it.

**Spawning badly beats not spawning at all.** The alternative is a player who stays
dead until a point frees up, which on a busy map with a short round is the rest of the
match. The count is in `describe()` so a map with too few spawn points is visible
rather than merely felt.

Threats are **enemies only**, and it is `_threats_against` that filters. A selector that
avoided the whole roster would scatter a team across the map; in a free-for-all,
team 0 makes everyone an enemy, which is the right answer there.

## The replicated clock is an absolute end tick

`DotMatchNetSync` sends `net_ends_at`, not `seconds_remaining`. A relative value would
be smaller and would have to be re-sent every tick to stay accurate. An absolute end
tick goes out once per state change, and every client counts down from the clock they
already share with the server — which is dot-net's, and which they are all already
running on.

`seconds_remaining` returns -1 for "no clock" on both the server and the client side, so
a HUD has one branch rather than two.

## Coupling: nothing is imported

dot-match names no class outside dot-core. Not dot-combat, not dot-net, not dot-server,
not dot-loadout.

- `DotMatchNetSync` describes what to replicate as data — property names and *type
  names as strings* — which a bridge resolves with `DotNetVar.Type[spec.type]`.
- Being alive is dot-combat's `DotHealth`, so `DotRulesElimination` takes an
  `alive_fn` rather than looking for one. Unwired, it warns and falls back to the
  clock — visible in the first round played, which is the point.
- Where a player is comes from `DotMatch.position_fn`.
- `DotTeamManager.team_lookup()` returns exactly the `Callable` that
  `DotDamageResolver.team_of` wants, without either project naming the other.
- Nothing here spawns anything. `respawn_due` carries a `DotSpawnPoint`; the game does
  the spawning, because what a player *is* is not dot-match's business.

The `DotModule` that binds a match to a dot-server belongs in the game, for the same
reason: dot-server is not a dependency.

## Validating changes

```bash
cd godot/dot-match
ln -s ../../dot-core/addons/dot_core addons/dot_core   # gitignored
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/match_selftest.tscn
```

114 checks, all offline. Exits non-zero on any failure.

**Run it after any change to the state machine.** The `pause_when_empty` bug parsed
cleanly and left the match stuck in `COUNTDOWN` forever; nothing but running a round
would have found it.

## Things deliberately not here

- **A dot-server module.** dot-server is not a dependency, and the bridge — a
  `DotModule` that forwards joins, leaves and deaths — is about forty lines that belong
  in the game. `game-arena` has one.
- **Objective modes.** `report_objective` carries a named counter and adds to a team
  score, which is the shared half. Capture points, flags, bomb sites and payloads all
  need world entities with their own state, and inventing a generic one before there is
  a second mode to check it against would be guesswork.
- **Map rotation.** dot-server already has `DotGameManager` and the game-switching
  machinery. A match that also rotated maps would be a second, competing owner of what
  is loaded.
- **Vote-to-skip, ready-up, warmup readiness.** dot-server has `DotVoteManager`.
  `min_players` and the warmup clock are what dot-match contributes.
- **Assist attribution.** `report_assist` exists and scores; deciding *who* assisted
  needs a damage history with a time window, which is dot-combat's `DotDamage` stream
  and a game's own policy about how long an assist lasts.
- **Persisted stats.** The scoreboard is per match and `reset_match` drops absent
  records. Anything that outlives a match is a profile, which is dot-user.
- **A HUD.** `describe_lines()` on everything is what a console command dumps.
  The scoreboard, the kill feed and the round timer as Controls belong in dot-ui.
