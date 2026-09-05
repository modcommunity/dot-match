@tool
class_name DotRulesElimination
extends DotMatchRules

## A round ends when one side has nobody left alive. Search and destroy, last man
## standing, and every round-based mode that does not respawn.
##
## Shipped because it is the one common mode whose win condition cannot be expressed
## with a score limit and a clock, and because writing it out is the clearest
## demonstration of what a [DotMatchRules] subclass is for.
##
## [b]It needs to know who is alive, and dot-match does not.[/b] Being alive is a
## `DotHealth` in dot-combat, which is not a dependency here — so the game supplies
## [member alive_fn] and this class asks.

## `func(key: String) -> bool`. Whether that player is alive right now.
##
## Left unset, this ruleset cannot decide anything and falls back to its parent's
## score-and-clock rule. That is loud in a specific way: the round runs to the clock
## instead of ending on the last kill, which is visible in the first round played.
var alive_fn: Callable = Callable()


static func make(round_sec: float = 120.0) -> DotRulesElimination:
	var rules := DotRulesElimination.new()
	rules.id = &"elimination"
	rules.display_name = "Elimination"
	rules.team_based = true
	rules.respawn_disabled = true
	rules.score_limit = 0
	rules.time_limit_sec = round_sec
	rules.rounds_to_win = 4
	rules.intermission_sec = 8.0
	return rules


func _round_outcome(
	scoreboard: DotScoreboard,
	teams: DotTeamManager,
	elapsed_sec: float
) -> Outcome:
	if not alive_fn.is_valid():
		DotLog.warn(
			"match.rules",
			"elimination rules have no alive_fn; falling back to score and clock"
		)
		return super._round_outcome(scoreboard, teams, elapsed_sec)

	if time_limit_sec > 0.0 and elapsed_sec >= time_limit_sec:
		return Outcome.TIME

	var standing := _teams_with_survivors(scoreboard, teams)

	# Zero is a mutual wipe — a grenade that killed the last two players — and it ends
	# the round as a draw. Treating it as "keep going" is a round that never ends, and
	# it happens often enough to matter.
	if standing.size() <= 1:
		return Outcome.ELIMINATION

	return Outcome.NONE


func _round_winner(scoreboard: DotScoreboard, teams: DotTeamManager) -> int:
	if not alive_fn.is_valid():
		return super._round_winner(scoreboard, teams)

	var standing := _teams_with_survivors(scoreboard, teams)

	if standing.size() == 1:
		return standing[0]

	# Nobody left, or the clock ran out with both sides alive: fall back to score.
	return super._round_winner(scoreboard, teams)


func _teams_with_survivors(
	scoreboard: DotScoreboard,
	teams: DotTeamManager
) -> Array[int]:
	var out: Array[int] = []

	if teams == null:
		return out

	for id in teams.playing_team_ids():
		for record in scoreboard.players_on(id):
			if bool(alive_fn.call(record.key)):
				out.append(id)
				break

	return out
