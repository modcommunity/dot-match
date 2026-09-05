@tool
class_name DotScoreboard
extends Node

## Who is playing and how they are doing.
##
## [b]Records outlive disconnections.[/b] A player who drops and reconnects gets their
## kills back, because the alternative — dropping the record on disconnect — is a
## scoreboard that rewards rage-quitting and punishes a bad connection. The record is
## marked absent and swept when the match ends.
##
## [b]Keyed by a stable player key, never a peer id.[/b] See [DotPlayerScore].

const CHANNEL := "match.score"

## A record was created for a key that had none.
signal player_added(record: DotPlayerScore)

## A player disconnected. The record is kept.
signal player_left(record: DotPlayerScore)

## Any counter changed. Coalesced per call, not per field, so a HUD binding to it
## refreshes once per event rather than five times.
signal score_changed(record: DotPlayerScore)

@export_group("Limits")

## Records kept at once, including absent ones. Above any real server on purpose: this
## is a bound against a churn of thousands of joins, not a player cap.
@export_range(8, 4096, 8) var max_records: int = 512

## key -> [DotPlayerScore].
var _records: Dictionary = {}

## team id -> accumulated team score.
var _team_scores: Dictionary = {}


## Finds or creates a record.
##
## Creating on lookup rather than requiring an explicit add: every call site otherwise
## has to handle "the player is not on the scoreboard yet", and the one that forgets
## silently drops a kill.
func record_for(key: String, display_name: String = "") -> DotPlayerScore:
	var record: DotPlayerScore = _records.get(key)

	if record != null:
		if display_name != "":
			record.display_name = display_name
		return record

	if _records.size() >= max_records:
		_evict_absent()

	record = DotPlayerScore.make(key, display_name)
	_records[key] = record
	player_added.emit(record)
	return record


func find(key: String) -> DotPlayerScore:
	return _records.get(key)


func has(key: String) -> bool:
	return _records.has(key)


## Marks a player present. What a join and a reconnect both call.
func join(key: String, display_name: String = "", team: int = 0) -> DotPlayerScore:
	var record := record_for(key, display_name)
	record.present = true

	if team > 0:
		record.team = team

	return record


func leave(key: String) -> void:
	var record: DotPlayerScore = _records.get(key)

	if record == null:
		return

	record.present = false
	record.streak = 0
	player_left.emit(record)


func forget(key: String) -> void:
	_records.erase(key)


## Drops the longest-absent records to make room.
##
## Absent records only: evicting a present player's record loses the score of someone
## who is still playing, which is far worse than losing a leaver's.
func _evict_absent() -> void:
	var absent: Array[String] = []

	for key in _records.keys():
		var record: DotPlayerScore = _records[key]
		if not record.present:
			absent.append(key)

	if absent.is_empty():
		DotLog.warn(
			CHANNEL,
			"scoreboard is full and every record is present; not evicting",
			{"records": _records.size()}
		)
		return

	absent.sort_custom(func(a: String, b: String) -> bool:
		return (_records[a] as DotPlayerScore).last_active_tick \
			< (_records[b] as DotPlayerScore).last_active_tick
	)

	_records.erase(absent[0])


# --- Events ----------------------------------------------------------------

## Records a kill. Returns the killer's record, or null for a world death.
##
## [param killer_key] empty, or equal to [param victim_key], is a suicide: the victim
## takes the death and, depending on [param suicide_penalty], loses a point. Handling
## both here rather than at the call site is what stops "the killer disconnected"
## being a crash.
func note_kill(
	killer_key: String,
	victim_key: String,
	tick: int,
	points: int = 1,
	suicide_penalty: int = -1,
	friendly_penalty: int = -1
) -> DotPlayerScore:
	var victim := record_for(victim_key)
	victim.note_death()
	victim.last_active_tick = tick

	if killer_key == "" or killer_key == victim_key:
		victim.suicides += 1
		victim.score += suicide_penalty
		score_changed.emit(victim)
		return null

	var killer := record_for(killer_key)
	killer.last_active_tick = tick

	if killer.team > 0 and killer.team == victim.team:
		killer.team_kills += 1
		killer.score += friendly_penalty
		# Deliberately not counted as a kill. A team kill that adds to the killer's
		# kill count makes farming team-mates a viable way up the scoreboard.
		score_changed.emit(killer)
		score_changed.emit(victim)
		return killer

	killer.note_kill(points)
	add_team_score(killer.team, points)

	score_changed.emit(killer)
	score_changed.emit(victim)
	return killer


func note_assist(key: String, tick: int, points: int = 0) -> void:
	if key == "":
		return

	var record := record_for(key)
	record.assists += 1
	record.score += points
	record.last_active_tick = tick
	score_changed.emit(record)


func note_damage(dealer_key: String, victim_key: String, amount: float) -> void:
	if dealer_key != "" and dealer_key != victim_key:
		record_for(dealer_key).damage_dealt += amount

	if victim_key != "":
		record_for(victim_key).damage_taken += amount


## Adds to a mode's own counter, and to the player's score.
##
## What a capture, a plant or a defuse uses. The counter name is the game's; dot-match
## only guarantees it is carried and reported.
func note_objective(
	key: String,
	counter: StringName,
	tick: int,
	points: int = 0
) -> void:
	var record := record_for(key)
	record.extra[counter] = int(record.extra.get(counter, 0)) + 1
	record.score += points
	record.last_active_tick = tick
	add_team_score(record.team, points)
	score_changed.emit(record)


func add_team_score(team: int, points: int) -> void:
	if team <= 0 or points == 0:
		return

	_team_scores[team] = int(_team_scores.get(team, 0)) + points


func team_score(team: int) -> int:
	return int(_team_scores.get(team, 0))


func team_scores() -> Dictionary:
	return _team_scores.duplicate()


func set_team(key: String, team: int) -> void:
	var record := record_for(key)
	record.team = team
	score_changed.emit(record)


# --- Queries ---------------------------------------------------------------

func players() -> Array[DotPlayerScore]:
	var out: Array[DotPlayerScore] = []
	for key in _records.keys():
		out.append(_records[key])
	return out


func present_players() -> Array[DotPlayerScore]:
	var out: Array[DotPlayerScore] = []
	for record in players():
		if record.present and not record.spectating:
			out.append(record)
	return out


func players_on(team: int) -> Array[DotPlayerScore]:
	var out: Array[DotPlayerScore] = []
	for record in present_players():
		if record.team == team:
			out.append(record)
	return out


func present_count() -> int:
	return present_players().size()


## Records sorted for display: score, then kills, then fewest deaths, then key.
##
## The final tie-break on the key is what makes this **stable across machines**. Two
## players tied on everything would otherwise be ordered by dictionary iteration order,
## which differs between a server and a client and produces a scoreboard where players
## visibly swap places for no reason.
func ranked() -> Array[DotPlayerScore]:
	var out := players()

	out.sort_custom(func(a: DotPlayerScore, b: DotPlayerScore) -> bool:
		if a.score != b.score:
			return a.score > b.score
		if a.kills != b.kills:
			return a.kills > b.kills
		if a.deaths != b.deaths:
			return a.deaths < b.deaths
		return a.key < b.key
	)

	return out


## The player in front, or null when nobody is.
func leader() -> DotPlayerScore:
	var order := ranked()
	return null if order.is_empty() else order[0]


## The highest score any single player has. For a score-limit win condition.
func best_score() -> int:
	var best := 0
	for record in present_players():
		best = maxi(best, record.score)
	return best


func leading_team() -> int:
	var best := 0
	var best_score_value := -2147483648

	for team in _team_scores.keys():
		var value := int(_team_scores[team])
		# Ties go to the lower team id, so two machines agree.
		if value > best_score_value or (value == best_score_value and int(team) < best):
			best_score_value = value
			best = int(team)

	return best


# --- Lifecycle -------------------------------------------------------------

## Zeroes every counter, keeping identities and teams. What a round reset does.
func reset_scores() -> void:
	for record in players():
		record.reset()
	_team_scores.clear()


## Drops absent records and zeroes everything. What a match end does.
func reset_match() -> void:
	for key in _records.keys():
		if not (_records[key] as DotPlayerScore).present:
			_records.erase(key)

	reset_scores()


func clear() -> void:
	_records.clear()
	_team_scores.clear()


func describe() -> Dictionary:
	var rows := []
	for record in ranked():
		rows.append(record.to_dictionary())

	return {
		"records": _records.size(),
		"present": present_count(),
		"teams": team_scores(),
		"players": rows,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("  %-18s %4s %4s %4s %6s" % ["player", "K", "D", "A", "score"])

	for record in ranked():
		out.append("  %-18s %4d %4d %4d %6d%s" % [
			record.display_name.substr(0, 18),
			record.kills,
			record.deaths,
			record.assists,
			record.score,
			"" if record.present else "  (gone)",
		])

	for team in _team_scores.keys():
		out.append("  team %-13d %19d" % [int(team), int(_team_scores[team])])

	return out
