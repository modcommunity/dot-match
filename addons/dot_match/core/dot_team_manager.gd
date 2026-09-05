@tool
class_name DotTeamManager
extends Node

## Who is on which side, and keeping the sides even.
##
## [b]Every decision here is deterministic given the scoreboard.[/b] Assignment picks
## the smallest team and breaks ties on the lower id; autobalance picks the
## longest-serving player on the larger team and breaks ties on the key. Neither uses
## randomness, because a server and a client that disagree about which team someone is
## on disagree about friendly fire — which is a player who cannot damage the enemy and
## can damage their own side.

const CHANNEL := "match.teams"

## A player's team changed. [param forced] distinguishes autobalance from a choice.
signal team_changed(key: String, from_team: int, to_team: int, forced: bool)

## Autobalance moved someone. Emitted in addition to [signal team_changed] so a game
## can apologise to them specifically.
signal balanced(key: String, to_team: int)

@export_group("Teams")

@export var teams: Array[DotTeam] = []

@export_group("Balance")

## Keep the sides within this many players of each other. Zero disables balancing.
@export_range(0, 8, 1) var max_difference: int = 1

## Move players to enforce it, rather than only refusing joins that would break it.
##
## Off is friendlier and drifts: refusing joins alone cannot fix an imbalance created
## by people leaving, which is how a game ends up 6-versus-2 with nobody having done
## anything wrong.
@export var force_balance: bool = true

## Do not move a player who has been on their team fewer than this many ticks.
##
## Being switched immediately after switching is the single most annoying thing an
## autobalancer does, and without a grace period two joins in a row can produce it.
@export_range(0, 36000, 60) var balance_grace_ticks: int = 1800

@export_group("Joining")

## Let a player pick their team. Off assigns everyone.
@export var allow_choice: bool = true

## Where a player with no team goes. Zero means "assign the smallest".
@export_range(0, 32, 1) var default_team: int = 0

## Where the scores and the roster live. Required.
var scoreboard: DotScoreboard = null

## key -> tick they joined their current team, for the grace period.
var _joined_at: Dictionary = {}

var _by_id: Dictionary = {}
var _indexed: bool = false


func reindex() -> void:
	_by_id.clear()
	for team in teams:
		if team != null and team.id > 0:
			_by_id[team.id] = team
	_indexed = true


func _ensure_indexed() -> void:
	if not _indexed:
		reindex()


func team(id: int) -> DotTeam:
	_ensure_indexed()
	return _by_id.get(id)


func team_ids() -> Array[int]:
	_ensure_indexed()
	var out: Array[int] = []
	for key in _by_id.keys():
		out.append(int(key))
	out.sort()
	return out


## Team ids that count for balance and for winning. Excludes spectators.
func playing_team_ids() -> Array[int]:
	var out: Array[int] = []
	for id in team_ids():
		if not team(id).is_spectator:
			out.append(id)
	return out


func is_team_mode() -> bool:
	return playing_team_ids().size() >= 2


func count_on(id: int) -> int:
	return scoreboard.players_on(id).size() if scoreboard != null else 0


func team_of(key: String) -> int:
	if scoreboard == null:
		return 0
	var record := scoreboard.find(key)
	return record.team if record != null else 0


## What [DotDamageResolver.team_of] wants. Bind this and friendly fire works.
func team_lookup() -> Callable:
	return func(id: Variant) -> int:
		return team_of(str(id))


# --- Assignment ------------------------------------------------------------

## The team a joining player should go on.
##
## The smallest playing team, ties to the lower id. Deterministic on purpose — see the
## class documentation.
func smallest_team() -> int:
	var best := 0
	var best_count := 2147483647

	for id in playing_team_ids():
		var team_res := team(id)

		if team_res.max_players > 0 and count_on(id) >= team_res.max_players:
			continue

		var count := count_on(id)

		if count < best_count:
			best_count = count
			best = id

	return best


## Puts a player on a team. Returns the team they ended up on, or 0.
func assign(key: String, tick: int, wanted: int = 0) -> DotResult:
	if scoreboard == null:
		return DotResult.fail(DotError.CODE_STATE, "No scoreboard.")

	var target := wanted

	if target > 0 and not allow_choice:
		target = 0

	if target > 0:
		var chosen := team(target)

		if chosen == null:
			return DotResult.fail(
				DotError.CODE_INVALID, "No team %d." % target
			)

		if not chosen.is_spectator and not _has_room(target, key):
			return DotResult.fail(
				DotError.CODE_FORBIDDEN,
				"Team %s is full." % chosen.display_name
			)

		if (
			max_difference > 0
			and not chosen.is_spectator
			and _would_unbalance(target, key)
		):
			return DotResult.fail(
				DotError.CODE_FORBIDDEN,
				"Team %s would be too far ahead in numbers." % chosen.display_name
			)
	else:
		target = default_team if default_team > 0 else smallest_team()

	if target <= 0:
		return DotResult.fail(
			DotError.CODE_STATE, "There is no team with room."
		)

	return _place(key, target, tick, false)


func _place(key: String, target: int, tick: int, forced: bool) -> DotResult:
	var record := scoreboard.record_for(key)
	var previous := record.team

	if previous == target:
		return DotResult.success(target)

	record.team = target
	record.spectating = team(target) != null and team(target).is_spectator
	record.streak = 0
	_joined_at[key] = tick

	team_changed.emit(key, previous, target, forced)

	if forced:
		balanced.emit(key, target)

	return DotResult.success(target)


func _has_room(id: int, key: String) -> bool:
	var chosen := team(id)

	if chosen == null:
		return false

	if chosen.max_players <= 0:
		return true

	# A player already on the team is not taking a new slot. Without this, switching
	# to a full team you are already on is refused, which is a confusing no-op.
	var occupied := count_on(id)

	if team_of(key) == id:
		occupied -= 1

	return occupied < chosen.max_players


## Whether putting [param key] on [param id] would push the sides too far apart.
func _would_unbalance(id: int, key: String) -> bool:
	var current := team_of(key)
	var after := count_on(id) + (0 if current == id else 1)
	var smallest := 2147483647

	for other in playing_team_ids():
		if other == id:
			continue
		var count := count_on(other) - (1 if current == other else 0)
		smallest = mini(smallest, count)

	if smallest == 2147483647:
		return false

	return after - smallest > max_difference


# --- Balancing -------------------------------------------------------------

## Whether the sides are within [member max_difference] of each other.
func is_balanced() -> bool:
	if max_difference <= 0:
		return true

	var counts: Array[int] = []

	for id in playing_team_ids():
		counts.append(count_on(id))

	if counts.size() < 2:
		return true

	counts.sort()
	return counts[counts.size() - 1] - counts[0] <= max_difference


## Moves players until the sides are even. Returns how many were moved.
##
## [b]Call this between rounds, not during one.[/b] Switching someone mid-fight takes
## a player who was winning a duel and puts them on the other side of it. The state
## machine calls it at round start; a game that wants it more often can, and should
## think about that first.
func rebalance(tick: int) -> int:
	if not force_balance or max_difference <= 0 or scoreboard == null:
		return 0

	var moved := 0

	# Bounded rather than while(not is_balanced()): a team with max_players full and
	# a grace period covering everyone can be permanently unbalanceable, and a loop
	# that assumed otherwise would hang the server between rounds.
	for _pass in range(32):
		if is_balanced():
			break

		var largest := _extreme_team(true)
		var smallest := _extreme_team(false)

		if largest <= 0 or smallest <= 0 or largest == smallest:
			break

		if not _has_room(smallest, ""):
			break

		var victim := _balance_candidate(largest, tick)

		if victim == "":
			# Everyone on the larger team is inside their grace period. Leaving it
			# uneven for now is better than switching someone who just switched.
			DotLog.debug(
				CHANNEL, "cannot balance: every candidate is inside the grace period"
			)
			break

		_place(victim, smallest, tick, true)
		moved += 1

	return moved


func _extreme_team(largest: bool) -> int:
	var best := 0
	var best_count := -1 if largest else 2147483647

	for id in playing_team_ids():
		var count := count_on(id)

		if largest and count > best_count:
			best_count = count
			best = id
		elif not largest and count < best_count:
			best_count = count
			best = id

	return best


## Who to move off an oversized team.
##
## The player who has been on it longest, ties broken on the key so two machines
## agree. Longest-serving rather than newest: the newest arrival is the one most
## likely to have just been assigned there by [method assign], and moving them
## immediately is the annoying case the grace period exists to prevent.
func _balance_candidate(from_team: int, tick: int) -> String:
	var best := ""
	var best_joined := 2147483647

	for record in scoreboard.players_on(from_team):
		var joined := int(_joined_at.get(record.key, 0))

		if tick - joined < balance_grace_ticks:
			continue

		if joined < best_joined or (joined == best_joined and record.key < best):
			best_joined = joined
			best = record.key

	return best


func forget(key: String) -> void:
	_joined_at.erase(key)


func validate() -> DotResult:
	reindex()

	if teams.is_empty():
		return DotResult.success(null)

	var seen := {}

	for team_res in teams:
		if team_res == null:
			return DotResult.fail(DotError.CODE_INVALID, "A null team.")

		var res := team_res.validate()

		if not res.ok:
			return res

		if seen.has(team_res.id):
			return DotResult.fail(
				DotError.CODE_INVALID, "Team id %d is declared twice." % team_res.id
			)

		seen[team_res.id] = true

	return DotResult.success(teams.size())


func describe() -> Dictionary:
	var out := {}

	for id in team_ids():
		out[str(id)] = {
			"name": team(id).display_name,
			"players": count_on(id),
			"score": scoreboard.team_score(id) if scoreboard != null else 0,
		}

	return {
		"teams": out,
		"balanced": is_balanced(),
		"team_mode": is_team_mode(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	for id in team_ids():
		out.append("  %-10s %2d players  %5d points" % [
			team(id).display_name,
			count_on(id),
			scoreboard.team_score(id) if scoreboard != null else 0,
		])

	if not is_balanced():
		out.append("  (unbalanced)")

	return out
