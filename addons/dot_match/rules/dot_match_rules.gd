@tool
class_name DotMatchRules
extends Resource

## What winning means, and what a kill is worth.
##
## Subclass this for a mode dot-match does not ship. [DotMatch] calls the four
## [code]_[/code]-prefixed methods and nothing else, so a mode can change every rule
## without touching the state machine.
##
## [b]Every method here must be a pure function of what it is given.[/b] They run on
## the server; if a game also runs them on a client to predict a round ending, anything
## that reads a clock or a node makes the two disagree.

## What ended a round or a match.
enum Outcome {
	## Still running.
	NONE,
	## Someone reached the score limit.
	SCORE,
	## The clock ran out.
	TIME,
	## Everyone on one side is out.
	ELIMINATION,
	## Not enough players to continue.
	ABANDONED,
	## A game's own condition. See [member outcome_reason].
	CUSTOM,
}

@export var id: StringName = &"deathmatch"

@export var display_name: String = "Deathmatch"

@export_group("Winning")

## Points to win. Zero means the score does not end a match.
@export_range(0, 10000, 1) var score_limit: int = 30

## Seconds a round lasts. Zero means no clock.
@export_range(0.0, 7200.0, 10.0) var time_limit_sec: float = 600.0

## Rounds to win a match. One means the match is one round.
@export_range(1, 15, 1) var rounds_to_win: int = 1

@export_group("Scoring")

## Points a kill is worth.
@export_range(0, 100, 1) var kill_points: int = 1

## Points for a suicide or a world death. Usually negative.
@export_range(-100, 100, 1) var suicide_points: int = -1

## Points for killing a team-mate. Usually negative, and never positive in a mode with
## friendly fire on — see [member friendly_kills_count].
@export_range(-100, 100, 1) var friendly_points: int = -1

## Points an assist is worth.
@export_range(0, 100, 1) var assist_points: int = 0

## Whether a team kill counts towards the killer's kill total.
##
## [b]Off, and it should stay off.[/b] A team kill that adds to the kill count makes
## farming team-mates a viable way up the scoreboard, and every mode that has shipped
## with it on has removed it.
@export var friendly_kills_count: bool = false

@export_group("Respawning")

## Seconds before a dead player comes back. Zero is instant.
@export_range(0.0, 120.0, 0.5) var respawn_delay_sec: float = 3.0

## Nobody respawns until the round ends. What an elimination mode is.
@export var respawn_disabled: bool = false

## Seconds of invulnerability on spawn.
@export_range(0.0, 30.0, 0.5) var spawn_protection_sec: float = 2.0

@export_group("Flow")

## Seconds of warmup before the first round. Zero starts immediately.
@export_range(0.0, 600.0, 5.0) var warmup_sec: float = 30.0

## Players needed before warmup can end. One lets a solo player start.
@export_range(1, 64, 1) var min_players: int = 2

## Seconds between "go" being decided and the round actually starting.
@export_range(0.0, 30.0, 0.5) var countdown_sec: float = 5.0

## Seconds a round-end screen is shown before the next round.
@export_range(0.0, 120.0, 1.0) var intermission_sec: float = 10.0

## Seconds the final scoreboard is shown before the match resets.
@export_range(0.0, 300.0, 5.0) var match_end_sec: float = 20.0

## Drop back to warmup when the player count falls below [member min_players].
##
## On is right for a public server, where a two-player match that becomes a one-player
## match should not keep running its clock down. Off is right for a scheduled match,
## and for a test that drives the loop with no players at all.
##
## This is a mode's rule rather than a server setting, because [member min_players] is:
## splitting the two across [DotMatchConfig] would leave a threshold in one file and
## the decision about what to do at it in another.
@export var pause_when_empty: bool = true

## Whether this mode has sides at all. Drives balance and the team win condition.
@export var team_based: bool = false


static func deathmatch(limit: int = 30) -> DotMatchRules:
	var rules := DotMatchRules.new()
	rules.id = &"deathmatch"
	rules.display_name = "Deathmatch"
	rules.score_limit = limit
	rules.team_based = false
	return rules


static func team_deathmatch(limit: int = 75) -> DotMatchRules:
	var rules := DotMatchRules.new()
	rules.id = &"tdm"
	rules.display_name = "Team Deathmatch"
	rules.score_limit = limit
	rules.team_based = true
	rules.friendly_points = -1
	return rules


# --- Subclass interface ----------------------------------------------------

## Points a kill is worth. Override for a mode where not all kills are equal.
##
## [param killer] is null for a world death.
func _points_for_kill(
	_killer: DotPlayerScore,
	_victim: DotPlayerScore
) -> int:
	return kill_points


## Whether the round is over, and why.
##
## Called after every scoring event and once per second of clock. Return
## [constant Outcome.NONE] to continue.
func _round_outcome(
	scoreboard: DotScoreboard,
	teams: DotTeamManager,
	elapsed_sec: float
) -> Outcome:
	if score_limit > 0:
		if team_based and teams != null and teams.is_team_mode():
			for id in teams.playing_team_ids():
				if scoreboard.team_score(id) >= score_limit:
					return Outcome.SCORE
		elif scoreboard.best_score() >= score_limit:
			return Outcome.SCORE

	if time_limit_sec > 0.0 and elapsed_sec >= time_limit_sec:
		return Outcome.TIME

	return Outcome.NONE


## Who won the round. A team id in team mode, 0 for a draw.
##
## In a free-for-all this is not a team id — it is meaningless, and the winner is
## [method DotScoreboard.leader]. Returning 0 there is correct, not a failure.
func _round_winner(
	scoreboard: DotScoreboard,
	teams: DotTeamManager
) -> int:
	if not team_based or teams == null or not teams.is_team_mode():
		return 0

	var best := 0
	var best_value := -2147483648
	var tied := false

	for id in teams.playing_team_ids():
		var value := scoreboard.team_score(id)

		if value > best_value:
			best_value = value
			best = id
			tied = false
		elif value == best_value:
			tied = true

	return 0 if tied else best


## Seconds before [param victim] respawns. Override for a mode with escalating
## penalties or a wave timer.
func _respawn_delay(_victim: DotPlayerScore) -> float:
	return respawn_delay_sec


# --- Called by DotMatch ----------------------------------------------------

func points_for_kill(killer: DotPlayerScore, victim: DotPlayerScore) -> int:
	if killer == null or (victim != null and killer.key == victim.key):
		return suicide_points

	if killer.team > 0 and victim != null and killer.team == victim.team:
		return friendly_points

	return _points_for_kill(killer, victim)


func round_outcome(
	scoreboard: DotScoreboard,
	teams: DotTeamManager,
	elapsed_sec: float
) -> Outcome:
	return _round_outcome(scoreboard, teams, elapsed_sec)


func round_winner(scoreboard: DotScoreboard, teams: DotTeamManager) -> int:
	return _round_winner(scoreboard, teams)


func respawn_delay(victim: DotPlayerScore) -> float:
	return _respawn_delay(victim)


func validate() -> DotResult:
	if score_limit <= 0 and time_limit_sec <= 0.0:
		# A round with neither ends only when a game's own subclass says so, which is
		# legitimate — an elimination mode does exactly that. It is also what a
		# half-configured ruleset looks like, and one is a mode and the other is a
		# server that never changes map.
		DotLog.warn(
			"match.rules",
			"a ruleset with no score limit and no time limit; "
			+ "only a custom outcome can end this round",
			{"id": String(id)}
		)

	if friendly_kills_count:
		DotLog.warn(
			"match.rules",
			"friendly kills count towards the kill total; "
			+ "this makes farming team-mates a way up the scoreboard",
			{"id": String(id)}
		)

	if respawn_disabled and rounds_to_win <= 1 and time_limit_sec <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Respawning is off in a single round with no clock, so a dead player "
			+ "never returns and the match never ends."
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"id": String(id),
		"name": display_name,
		"team_based": team_based,
		"score_limit": score_limit,
		"time_limit": time_limit_sec,
		"rounds": rounds_to_win,
		"respawn": "off" if respawn_disabled else "%.1fs" % respawn_delay_sec,
	}


func _to_string() -> String:
	return "DotMatchRules(%s)" % id
