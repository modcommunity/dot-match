class_name DotPlayerScore
extends RefCounted

## One player's record for one match.
##
## [b]Keyed by a stable player key, never by a peer id.[/b] A peer id is reassigned the
## moment someone reconnects, and a scoreboard keyed by one hands the next player to
## join the previous player's kills. dot-server's session ids and dot-user's scoped ids
## are both stable; a transport peer id is not.

## Stable identity. A dot-user scoped id, a dot-server session id — whatever the game
## uses, as long as it survives a reconnect.
var key: String = ""

## Shown on a scoreboard. May change mid-match; nothing keys on it.
var display_name: String = ""

var team: int = 0

var kills: int = 0
var deaths: int = 0
var assists: int = 0

## Deaths caused by the player themselves or by the world. Counted in [member deaths]
## as well; this is the subset a scoreboard usually shows separately.
var suicides: int = 0

## Team-mates killed. Also in [member kills] unless the rules say otherwise — see
## [member DotMatchRules.friendly_kills_count].
var team_kills: int = 0

## Mode-specific points. What a win condition actually reads: a capture mode scores by
## captures, not by kills, and both need somewhere to go.
var score: int = 0

## Kills without dying. Reset on death.
var streak: int = 0

## Longest [member streak] this match.
var best_streak: int = 0

## Damage dealt and taken, for a scoreboard that shows it.
var damage_dealt: float = 0.0
var damage_taken: float = 0.0

## Tick this player last did anything, for idle detection.
var last_active_tick: int = 0

## Whether they are connected. A disconnected player's record is kept for the rest of
## the match so a reconnect restores it — see [DotScoreboard].
var present: bool = true

## Whether they are on a spectator team. Excluded from win conditions and balance.
var spectating: bool = false

## Free-form space for a game mode's own counters: captures, plants, revives.
var extra: Dictionary = {}


static func make(p_key: String, p_name: String = "") -> DotPlayerScore:
	var record := DotPlayerScore.new()
	record.key = p_key
	record.display_name = p_name if p_name != "" else p_key.substr(0, 8)
	return record


## Kills minus deaths. The number a deathmatch actually sorts by when
## [member score] is unused.
func net_kills() -> int:
	return kills - deaths


func ratio() -> float:
	return float(kills) if deaths == 0 else float(kills) / float(deaths)


## Zeroes everything except identity and team. What a round reset does.
##
## [member team] survives on purpose: a round reset that reassigned teams would shuffle
## the sides between rounds of the same match.
func reset() -> void:
	kills = 0
	deaths = 0
	assists = 0
	suicides = 0
	team_kills = 0
	score = 0
	streak = 0
	best_streak = 0
	damage_dealt = 0.0
	damage_taken = 0.0
	extra.clear()


func note_kill(points: int = 1) -> void:
	kills += 1
	score += points
	streak += 1
	best_streak = maxi(best_streak, streak)


func note_death() -> void:
	deaths += 1
	streak = 0


func to_dictionary() -> Dictionary:
	return {
		"key": key,
		"name": display_name,
		"team": team,
		"kills": kills,
		"deaths": deaths,
		"assists": assists,
		"score": score,
		"streak": streak,
		"best_streak": best_streak,
		"present": present,
		"spectating": spectating,
	}


func describe() -> Dictionary:
	var out := to_dictionary()
	out["suicides"] = suicides
	out["team_kills"] = team_kills
	out["damage_dealt"] = damage_dealt
	out["damage_taken"] = damage_taken
	out["extra"] = extra
	return out


func _to_string() -> String:
	return "DotPlayerScore(%s %d/%d/%d)" % [display_name, kills, deaths, assists]
