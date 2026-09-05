@tool
class_name DotMatch
extends Node

## The match loop: warmup, countdown, live, round end, match end.
##
## [b]Everything is counted in ticks and driven by one call.[/b] Nothing here uses a
## [Timer], a [method Node._process] or a wall clock. A match that ticks itself ticks
## on whatever schedule the engine gives it, which is not the schedule the simulation
## runs on, and a server whose round timer and whose netcode disagree about what time
## it is produces a round that ends on a different tick for every client.
##
## [b]No autoload.[/b] It registers itself in [DotRegistry] under [constant SERVICE].
## A process running two matches — which is what a test does — needs two of these, and
## [member service_scope] is how they coexist.
##
## [codeblock]
## var match_node := DotMatch.new()
## match_node.rules = DotMatchRules.deathmatch(30)
## match_node.scoreboard = scoreboard
## add_child(match_node)
##
## # Once per simulated tick, on the server.
## match_node.tick(tick)
##
## # When someone dies.
## match_node.report_kill(killer_key, victim_key, &"rifle", tick)
## [/codeblock]

const CHANNEL := "match"
const SERVICE := &"dot_match"

## Where a match is.
enum State {
	## Nothing is running.
	IDLE,
	## Waiting for players, or for the warmup clock. Nobody scores.
	WARMUP,
	## Everyone is in and the round is about to start.
	COUNTDOWN,
	## The round is running.
	LIVE,
	## The round is over and the next one has not started.
	INTERMISSION,
	## Every round is over.
	MATCH_END,
}

signal state_changed(from: State, to: State)

## A round began. [param round_number] is 1-based.
signal round_started(round_number: int)

## A round ended. [param winner] is a team id in team mode and 0 otherwise; check
## [param outcome] to tell a draw from a free-for-all.
signal round_ended(round_number: int, winner: int, outcome: DotMatchRules.Outcome)

## Every round is over.
signal match_ended(winner: int, outcome: DotMatchRules.Outcome)

## Someone should be put back in the world. The game does the spawning; dot-match only
## decides when and where.
signal respawn_due(key: String, spawn: DotSpawnPoint, tick: int)

## A kill was recorded, after the scoreboard and the feed have seen it.
signal kill_recorded(entry: DotKillFeed.Entry)

## A player has done nothing for [member DotMatchConfig.idle_seconds]. What to do
## about it is a server policy; dot-match only says so.
signal player_idle(key: String)

@export_group("Configuration")

@export var config: DotMatchConfig = null

@export var config_file: String = "user://cfg/match.json"

@export var load_layered_config: bool = false

@export_group("Rules")

## What winning means. Required.
@export var rules: DotMatchRules = null

@export_group("Service")

@export var register_service: bool = true

@export var service_scope: StringName = &""

@export_group("Wiring")

## Where the spawn points live. Empty searches from the current scene root.
@export var spawns_ref: DotNodeRef = null

## Who is playing and how they are doing. Created if left null.
var scoreboard: DotScoreboard = null

## Sides and balance. Created if left null; a free-for-all leaves its team list empty.
var teams: DotTeamManager = null

var feed: DotKillFeed = null

var respawns: DotRespawnQueue = null

var spawns: DotSpawnSelector = null

## `func(key: String) -> Vector3`. Where a player is, for spawn danger scoring.
##
## Left unset, spawn selection ignores where everyone is and falls back to cooldowns
## alone — which works and is much worse, because it will happily spawn someone in
## front of the player who just killed them.
var position_fn: Callable = Callable()

var state: State = State.IDLE

## 1-based. Zero before the first round.
var round_number: int = 0

## Tick the current state began on.
var state_since_tick: int = 0

## Rounds won, by team id. Free-for-all uses key 0 for "rounds played".
var rounds_won: Dictionary = {}

var _spawn_points: Array[DotSpawnPoint] = []
var _registered_name: StringName = &""
var _current_tick: int = 0
var _last_outcome: DotMatchRules.Outcome = DotMatchRules.Outcome.NONE
var _last_winner: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	var res := setup()

	if not res.ok:
		DotLog.result(CHANNEL, "match setup", res)
		return

	if config.auto_start:
		start(0)


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""


func setup() -> DotResult:
	if config == null:
		config = DotMatchConfig.new()

	if load_layered_config:
		var loaded := config.load_layered(config_file)
		if not loaded.ok:
			return loaded.wrap("Could not load the match configuration.")

	var valid := config.validate()

	if not valid.ok:
		return valid

	if rules == null:
		rules = DotMatchRules.deathmatch()

	var rules_res := rules.validate()

	if not rules_res.ok:
		return rules_res.wrap("The match rules are not usable.")

	if scoreboard == null:
		scoreboard = DotScoreboard.new()
		scoreboard.name = "Scoreboard"
		add_child(scoreboard)

	if teams == null:
		teams = DotTeamManager.new()
		teams.name = "Teams"
		if rules.team_based:
			teams.teams = DotTeam.standard_pair()
		add_child(teams)

	teams.scoreboard = scoreboard

	var teams_res := teams.validate()

	if not teams_res.ok:
		return teams_res

	if feed == null:
		feed = DotKillFeed.new()
		feed.name = "KillFeed"
		add_child(feed)

	if respawns == null:
		respawns = DotRespawnQueue.new(config.tick_rate)
	else:
		respawns.set_tick_rate(config.tick_rate)

	if spawns == null:
		spawns = DotSpawnSelector.new()

	refresh_spawns()

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &""
			else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	return DotResult.success(null)


## Re-collects the spawn points. Call after loading a level.
func refresh_spawns() -> void:
	_spawn_points.clear()

	var root: Node = null

	if spawns_ref != null:
		root = spawns_ref.resolve_or_null(self, CHANNEL)

	if root == null:
		root = get_tree().current_scene if is_inside_tree() else null

	if root == null:
		root = self

	_collect_spawns(root)

	if _spawn_points.is_empty():
		# Not an error — a test and a lobby both legitimately have none — but a
		# deathmatch with no spawn points is a match nobody can play, and the symptom
		# is players who never appear rather than anything failing.
		DotLog.warn(CHANNEL, "no spawn points found", {"root": root.name})
	else:
		DotLog.debug(CHANNEL, "spawn points", {"count": _spawn_points.size()})


func _collect_spawns(node: Node) -> void:
	for child in node.get_children():
		if child is DotSpawnPoint:
			_spawn_points.append(child)
		_collect_spawns(child)


func spawn_points() -> Array[DotSpawnPoint]:
	return _spawn_points


## Adds a spawn point that is not in the scene. For a level built at runtime.
func add_spawn_point(point: DotSpawnPoint) -> void:
	if point != null and not _spawn_points.has(point):
		_spawn_points.append(point)


# --- State machine ---------------------------------------------------------

func start(tick: int = 0) -> void:
	_current_tick = tick
	round_number = 0
	rounds_won.clear()
	scoreboard.reset_match()
	_transition(State.WARMUP, tick)


func stop(tick: int = -1) -> void:
	_transition(State.IDLE, tick if tick >= 0 else _current_tick)


func is_live() -> bool:
	return state == State.LIVE


## Whether scoring counts. Warmup deliberately does not.
func is_scoring() -> bool:
	return state == State.LIVE


func _transition(to: State, tick: int) -> void:
	if to == state:
		return

	var from := state
	state = to
	state_since_tick = tick

	if config.log_transitions:
		DotLog.info(CHANNEL, "state", {
			"from": State.keys()[from],
			"to": State.keys()[to],
			"tick": tick,
			"round": round_number,
		})

	state_changed.emit(from, to)


func _ticks_in_state(tick: int) -> int:
	return tick - state_since_tick


func seconds_in_state(tick: int = -1) -> float:
	var at := tick if tick >= 0 else _current_tick
	return float(_ticks_in_state(at)) / float(config.tick_rate)


## Seconds left in whatever is being waited for. Negative when nothing is.
func seconds_remaining(tick: int = -1) -> float:
	var at := tick if tick >= 0 else _current_tick
	var elapsed := float(_ticks_in_state(at)) / float(config.tick_rate)

	match state:
		State.WARMUP:
			return maxf(0.0, rules.warmup_sec - elapsed) if rules.warmup_sec > 0.0 else -1.0
		State.COUNTDOWN:
			return maxf(0.0, rules.countdown_sec - elapsed)
		State.LIVE:
			return maxf(0.0, rules.time_limit_sec - elapsed) if rules.time_limit_sec > 0.0 else -1.0
		State.INTERMISSION:
			return maxf(0.0, rules.intermission_sec - elapsed)
		State.MATCH_END:
			return maxf(0.0, rules.match_end_sec - elapsed)
		_:
			return -1.0


## Advances the match by one simulated tick.
##
## The only thing that moves the match. Call it from whatever already runs at tick
## rate — the netcode's tick signal, or a fixed-step loop.
func tick(current_tick: int) -> void:
	_current_tick = current_tick

	if state == State.IDLE:
		return

	_drain_respawns(current_tick)
	_check_idle(current_tick)

	match state:
		State.WARMUP:
			_tick_warmup(current_tick)
		State.COUNTDOWN:
			_tick_countdown(current_tick)
		State.LIVE:
			_tick_live(current_tick)
		State.INTERMISSION:
			_tick_intermission(current_tick)
		State.MATCH_END:
			_tick_match_end(current_tick)
		_:
			pass


func _enough_players() -> bool:
	return scoreboard.present_count() >= rules.min_players


func _tick_warmup(current_tick: int) -> void:
	if not _enough_players():
		# The warmup clock restarts while the server is short-handed, rather than
		# expiring and starting a round into an empty server.
		state_since_tick = current_tick
		return

	if rules.warmup_sec > 0.0 and seconds_in_state(current_tick) < rules.warmup_sec:
		return

	_transition(State.COUNTDOWN, current_tick)


func _tick_countdown(current_tick: int) -> void:
	if rules.pause_when_empty and not _enough_players():
		_transition(State.WARMUP, current_tick)
		return

	if seconds_in_state(current_tick) < rules.countdown_sec:
		return

	_begin_round(current_tick)


func _begin_round(current_tick: int) -> void:
	round_number += 1

	scoreboard.reset_scores()
	feed.clear()
	respawns.clear()

	for point in _spawn_points:
		point.reset()

	if config.balance_between_rounds and rules.team_based:
		teams.rebalance(current_tick)

	_transition(State.LIVE, current_tick)
	round_started.emit(round_number)

	# Everyone in at once, on this tick. A round that started by leaving people in the
	# respawn queue would begin with half the players still dead.
	for record in scoreboard.present_players():
		respawns.enqueue_at(record.key, current_tick)

	_drain_respawns(current_tick)


func _tick_live(current_tick: int) -> void:
	if rules.pause_when_empty and not _enough_players():
		_end_round(current_tick, DotMatchRules.Outcome.ABANDONED)
		return

	var outcome := rules.round_outcome(
		scoreboard, teams, seconds_in_state(current_tick)
	)

	if outcome != DotMatchRules.Outcome.NONE:
		_end_round(current_tick, outcome)


func _end_round(current_tick: int, outcome: DotMatchRules.Outcome) -> void:
	var winner := rules.round_winner(scoreboard, teams)

	_last_outcome = outcome
	_last_winner = winner

	if winner > 0:
		rounds_won[winner] = int(rounds_won.get(winner, 0)) + 1

	respawns.clear()

	round_ended.emit(round_number, winner, outcome)

	if _match_is_over(winner):
		_transition(State.MATCH_END, current_tick)
		match_ended.emit(winner, outcome)
		return

	_transition(State.INTERMISSION, current_tick)


func _match_is_over(_winner: int) -> bool:
	if rules.rounds_to_win <= 1:
		return true

	for team in rounds_won.keys():
		if int(rounds_won[team]) >= rules.rounds_to_win:
			return true

	# A best-of series has a bound on how many rounds can be played, and without it a
	# series of draws runs forever.
	var played := 0
	for team in rounds_won.keys():
		played += int(rounds_won[team])

	return round_number >= rules.rounds_to_win * 2 - 1 and played > 0


func _tick_intermission(current_tick: int) -> void:
	if seconds_in_state(current_tick) < rules.intermission_sec:
		return

	if rules.pause_when_empty and not _enough_players():
		_transition(State.WARMUP, current_tick)
		return

	_begin_round(current_tick)


func _tick_match_end(current_tick: int) -> void:
	if seconds_in_state(current_tick) < rules.match_end_sec:
		return

	start(current_tick)


# --- Players ---------------------------------------------------------------

## Adds a player. Assigns them a team in a team mode.
func add_player(key: String, display_name: String, tick: int, wanted_team: int = 0) -> DotResult:
	var record := scoreboard.join(key, display_name)
	record.last_active_tick = tick

	if rules.team_based and teams.is_team_mode():
		var assigned := teams.assign(key, tick, wanted_team)

		if not assigned.ok:
			return assigned

	# A player joining mid-round is queued rather than spawned here: spawning from a
	# join handler puts them in the world before whatever the game does on join has
	# run, and the respawn path already knows how to pick a safe point.
	if is_live() and not rules.respawn_disabled:
		respawns.enqueue(key, tick, rules.respawn_delay_sec)

	return DotResult.success(record)


## Marks a player gone. Their scoreboard record is kept for the rest of the match.
func remove_player(key: String) -> void:
	scoreboard.leave(key)
	respawns.cancel(key)
	teams.forget(key)


func switch_team(key: String, team: int, tick: int) -> DotResult:
	if not rules.team_based:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "This mode has no teams."
		)

	return teams.assign(key, tick, team)


## Records a kill: the scoreboard, the feed, the respawn timer, and the win check.
##
## [param killer_key] may be empty for a world death, and may equal [param victim_key]
## for a suicide. Both go through here rather than through separate methods, because
## every caller would otherwise have to work out which case it is and the one that gets
## it wrong credits a kill to nobody.
##
## **Does nothing but note the death outside [constant State.LIVE].** A kill during
## warmup must not score, and a kill during intermission must not restart a round that
## has already ended.
func report_kill(
	killer_key: String,
	victim_key: String,
	cause: StringName,
	tick: int,
	headshot: bool = false
) -> DotKillFeed.Entry:
	var victim := scoreboard.record_for(victim_key)
	var killer: DotPlayerScore = (
		null if killer_key == "" or killer_key == victim_key
		else scoreboard.record_for(killer_key)
	)

	var points := rules.points_for_kill(killer, victim)

	if is_scoring():
		scoreboard.note_kill(
			killer_key,
			victim_key,
			tick,
			points,
			rules.suicide_points,
			rules.friendly_points
		)
	else:
		# Outside a live round the death is still real — the player is on the floor —
		# but nothing about it counts.
		victim.note_death()

	var entry := feed.add_kill(killer, victim, cause, tick, headshot)
	kill_recorded.emit(entry)

	if not rules.respawn_disabled:
		respawns.enqueue(victim_key, tick, rules.respawn_delay(victim))

	if is_live():
		_tick_live(tick)

	return entry


## Records an assist, if the mode scores them.
func report_assist(key: String, tick: int) -> void:
	if not is_scoring():
		return

	scoreboard.note_assist(key, tick, rules.assist_points)


## Records a mode-specific objective: a capture, a plant, a defuse.
##
## Runs the win check afterwards, because in a mode scored by objectives that is what
## ends the round — and a caller that had to remember to run it is a caller that
## eventually does not.
func report_objective(
	key: String,
	counter: StringName,
	tick: int,
	points: int = 1
) -> void:
	if not is_scoring():
		return

	scoreboard.note_objective(key, counter, tick, points)

	if is_live():
		_tick_live(tick)


func report_damage(dealer_key: String, victim_key: String, amount: float) -> void:
	scoreboard.note_damage(dealer_key, victim_key, amount)


# --- Spawning --------------------------------------------------------------

func _drain_respawns(current_tick: int) -> void:
	if state != State.LIVE:
		return

	for key in respawns.take_ready(current_tick):
		var record := scoreboard.find(key)

		if record == null or not record.present or record.spectating:
			continue

		respawn_due.emit(key, choose_spawn(key, current_tick), current_tick)


## Picks where [param key] should appear.
##
## Public so a game can spawn someone outside the queue — a round start it drives
## itself, a spectator joining play, an admin's respawn command.
func choose_spawn(key: String, tick: int, tag: StringName = &"") -> DotSpawnPoint:
	var record := scoreboard.find(key)
	var team := record.team if record != null else 0

	# The team's own spawns, unless the caller named a tag. DotTeam.spawn_tag was
	# documented from the first version and read by nothing, so every team spawned
	# from the untagged pool — in a team game, in the other team's base.
	if tag == &"" and team > 0 and teams != null:
		var side := teams.team(team)
		if side != null:
			tag = side.spawn_tag

	spawns.threats = _threats_against(team, key)

	return spawns.choose(_spawn_points, tick, team, tag)


## Where the enemies of [param team] are.
##
## Enemies only. Spawning people away from their own team scatters a squad across the
## map, which is the opposite of what a team mode wants — and in a free-for-all
## everyone except the spawning player is an enemy, which is what team 0 produces here.
func _threats_against(team: int, key: String) -> Array[Vector3]:
	var out: Array[Vector3] = []

	if not position_fn.is_valid():
		return out

	for record in scoreboard.present_players():
		if record.key == key:
			continue

		if team > 0 and record.team == team:
			continue

		var value: Variant = position_fn.call(record.key)

		if value is Vector3:
			out.append(value)

	return out


## Seconds of spawn protection a freshly spawned player gets, in ticks.
##
## Returned in ticks because that is what `DotHealth.spawn_protection_ticks` wants and
## converting at the call site is how the two end up disagreeing.
func spawn_protection_ticks() -> int:
	return int(round(rules.spawn_protection_sec * float(config.tick_rate)))


# --- Idle ------------------------------------------------------------------

func _check_idle(current_tick: int) -> void:
	if config.idle_seconds <= 0.0 or state != State.LIVE:
		return

	var threshold := int(config.idle_seconds * float(config.tick_rate))

	for record in scoreboard.present_players():
		if current_tick - record.last_active_tick < threshold:
			continue

		# Stamped so the signal fires once per idle period rather than every tick
		# after the threshold, which would be sixty a second forever.
		record.last_active_tick = current_tick
		player_idle.emit(record.key)


## Marks a player as having done something. A game calls this from movement or fire.
func note_activity(key: String, tick: int) -> void:
	var record := scoreboard.find(key)

	if record != null:
		record.last_active_tick = tick


## Who won the most recent round or match. Zero for a draw or a free-for-all.
func last_winner() -> int:
	return _last_winner


func last_outcome() -> DotMatchRules.Outcome:
	return _last_outcome


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"state": State.keys()[state],
		"round": round_number,
		"rules": rules.describe() if rules != null else {},
		"remaining": seconds_remaining(),
		"players": scoreboard.present_count(),
		"rounds_won": rounds_won,
		"last_outcome": DotMatchRules.Outcome.keys()[_last_outcome],
		"last_winner": _last_winner,
		"spawns": _spawn_points.size(),
		"respawning": respawns.waiting_count(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("match    %s  round %d  %s" % [
		State.keys()[state],
		round_number,
		"%.0fs left" % seconds_remaining() if seconds_remaining() >= 0.0 else "no clock",
	])
	out.append("mode     %s" % (rules.display_name if rules != null else "<none>"))
	out.append("players  %d present, %d respawning" % [
		scoreboard.present_count(), respawns.waiting_count()
	])

	out.append_array(scoreboard.describe_lines())

	if rules != null and rules.team_based:
		out.append_array(teams.describe_lines())

	return out
