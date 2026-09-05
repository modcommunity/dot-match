extends Node

## Exercises everything in dot-match, offline and headless.
##
## [codeblock]
## godot --headless --path . res://examples/match_selftest.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## The cases that matter most are the ones a match only reaches after twenty minutes
## with real players: a round that never ends, a scoreboard that hands a reconnecting
## player someone else's kills, an autobalancer that switches the same person twice,
## and two machines that disagree about which spawn point was chosen.

const TICK_RATE := 60

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-match self-test")
	print("")

	_test_teams()
	_test_scoreboard()
	_test_scoreboard_reconnect()
	_test_kill_feed()
	_test_respawn_queue()
	_test_spawn_points()
	_test_spawn_selection()
	_test_rules()
	_test_flow_warmup()
	_test_flow_deathmatch()
	_test_flow_rounds()
	_test_team_assignment()
	_test_team_spawn_tags()
	_test_balance()
	_test_elimination()
	_test_kills_outside_live()
	_test_net_sync()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- Assertions ------------------------------------------------------------

func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


func _close(a: float, b: float, what: String, epsilon: float = 0.01) -> bool:
	return _check(absf(a - b) <= epsilon, what, "%.3f vs %.3f" % [a, b])


func _group(title: String) -> void:
	print("")
	print("%s" % title)


# --- Fixtures --------------------------------------------------------------

func _make_match(rules: DotMatchRules, with_teams: bool = false) -> DotMatch:
	var node := DotMatch.new()
	node.register_service = false
	node.rules = rules
	node.config = DotMatchConfig.new()
	node.config.tick_rate = TICK_RATE
	node.config.auto_start = false
	node.config.log_transitions = false
	node.config.idle_seconds = 0.0

	if with_teams:
		var manager := DotTeamManager.new()
		manager.teams = DotTeam.standard_pair()
		node.teams = manager
		node.add_child(manager)

	add_child(node)
	return node


func _quick_rules(limit: int = 3) -> DotMatchRules:
	var rules := DotMatchRules.deathmatch(limit)
	rules.warmup_sec = 1.0
	rules.countdown_sec = 0.5
	rules.time_limit_sec = 10.0
	rules.min_players = 2
	rules.respawn_delay_sec = 0.5
	rules.intermission_sec = 1.0
	rules.match_end_sec = 1.0
	return rules


## Runs the match forward, one tick at a time, from [param from] for [param ticks].
func _advance(node: DotMatch, from: int, ticks: int) -> int:
	for offset in range(ticks):
		node.tick(from + offset)
	return from + ticks


# --- Teams -----------------------------------------------------------------

func _test_teams() -> void:
	_group("teams")

	var red := DotTeam.make(1, "Red")
	_check(red.validate().ok, "a team with a positive id validates")

	var zero := DotTeam.make(0, "Nobody")
	zero.id = 0
	_check(
		not zero.validate().ok,
		"team id 0 is refused, because 0 means 'no team' everywhere"
	)

	var pair := DotTeam.standard_pair()
	_check(pair.size() == 2 and pair[0].id == 1, "the standard pair is 1 and 2")

	var spectators := DotTeam.spectators()
	_check(spectators.is_spectator, "spectators are marked as such")


# --- Scoreboard ------------------------------------------------------------

func _test_scoreboard() -> void:
	_group("scoreboard")

	var board := DotScoreboard.new()
	add_child(board)

	var alice := board.join("alice", "Alice")
	var bob := board.join("bob", "Bob")

	_check(board.present_count() == 2, "joining puts players on the board")

	board.note_kill("alice", "bob", 100, 1, -1, -1)
	_check(alice.kills == 1 and alice.score == 1, "a kill scores")
	_check(bob.deaths == 1, "and the victim takes the death")
	_check(alice.streak == 1, "and a streak")

	board.note_kill("bob", "alice", 110, 1, -1, -1)
	_check(alice.streak == 0, "dying resets a streak")
	_check(alice.best_streak == 1, "but not the best one")

	# A world death and a suicide are the same call with an empty or matching killer,
	# because every caller would otherwise have to work out which case it is.
	var before_world := bob.score
	var world := board.note_kill("", "bob", 120, 1, -2, -1)
	_check(world == null, "a world death has no killer")
	_check(
		bob.suicides == 1 and bob.score == before_world - 2,
		"and costs the victim the suicide penalty",
		"%d -> %d" % [before_world, bob.score]
	)

	board.set_team("alice", 1)
	board.set_team("bob", 1)
	var before_friendly := alice.score
	board.note_kill("alice", "bob", 130, 1, -1, -5)
	_check(alice.team_kills == 1, "a team kill is counted as one")
	_check(
		alice.kills == 1,
		"and deliberately does not add to the kill total",
		"kills %d" % alice.kills
	)
	_check(
		alice.score == before_friendly - 5,
		"but does cost the friendly-fire penalty",
		"%d -> %d" % [before_friendly, alice.score]
	)

	board.add_team_score(1, 10)
	_check(board.team_score(1) == 10, "team score accumulates")

	# The tie-break on the key is what stops a scoreboard reordering itself between
	# two machines that iterate their dictionaries differently.
	var tied := DotScoreboard.new()
	add_child(tied)
	for name_str in ["zoe", "adam", "mike"]:
		tied.join(name_str, name_str)
	var order := tied.ranked()
	_check(
		order[0].key == "adam" and order[2].key == "zoe",
		"players tied on everything are ordered by key, not by iteration order",
		"%s,%s,%s" % [order[0].key, order[1].key, order[2].key]
	)

	board.queue_free()
	remove_child(board)
	tied.queue_free()
	remove_child(tied)


func _test_scoreboard_reconnect() -> void:
	_group("scoreboard: reconnecting")

	var board := DotScoreboard.new()
	add_child(board)

	board.join("alice", "Alice")
	board.note_kill("alice", "bob", 100, 1, -1, -1)

	board.leave("alice")
	_check(board.find("alice") != null, "a record survives a disconnection")
	_check(not board.find("alice").present, "marked absent")
	_check(board.present_count() == 1, "and out of the present count")

	var back := board.join("alice", "Alice")
	_check(back.kills == 1, "and a reconnecting player gets their kills back")
	_check(back.present, "and is present again")

	# Eviction must never take a present player's record.
	var small := DotScoreboard.new()
	small.max_records = 8
	add_child(small)

	for index in range(8):
		small.join("player_%d" % index, "P%d" % index)

	small.record_for("overflow")
	_check(
		small.find("player_0") != null,
		"a full scoreboard does not evict a present player"
	)

	small.leave("player_0")
	small.find("player_0").last_active_tick = 0
	small.record_for("overflow2")
	_check(small.find("player_0") == null, "but does evict an absent one")

	board.queue_free()
	remove_child(board)
	small.queue_free()
	remove_child(small)


# --- Kill feed -------------------------------------------------------------

func _test_kill_feed() -> void:
	_group("kill feed")

	var feed := DotKillFeed.new()
	feed.capacity = 4
	add_child(feed)

	var killer := DotPlayerScore.make("alice", "Alice")
	var victim := DotPlayerScore.make("bob", "Bob")

	var entry := feed.add_kill(killer, victim, &"rifle", 100, true)
	_check(entry.headshot, "a headshot is marked")
	_check(not entry.suicide, "and a normal kill is not a suicide")

	# The case that is a null dereference if it is not handled here: killed by
	# somebody who has already left.
	var orphan := feed.add_kill(null, victim, &"fall", 110)
	_check(orphan.suicide, "a kill with no killer is a suicide")
	_check(orphan.killer_key == "", "with no killer key")

	killer.team = 1
	victim.team = 1
	var friendly := feed.add_kill(killer, victim, &"rifle", 120)
	_check(friendly.team_kill, "a team kill is marked")

	for index in range(10):
		feed.add_kill(killer, victim, &"rifle", 200 + index)

	_check(feed.entries().size() == 4, "the feed is bounded", str(feed.entries().size()))
	_check(feed.recent(2).size() == 2, "and can be read from the end")
	_check(feed.since(205).size() == 4, "and from a tick")

	feed.queue_free()
	remove_child(feed)


# --- Respawns --------------------------------------------------------------

func _test_respawn_queue() -> void:
	_group("respawn queue")

	var queue := DotRespawnQueue.new(TICK_RATE)

	queue.enqueue("alice", 100, 1.0)
	_check(queue.is_waiting("alice"), "a dead player waits")
	_close(queue.seconds_remaining("alice", 100), 1.0, "for the stated time")

	_check(queue.take_ready(150).is_empty(), "and does not come back early")

	var ready := queue.take_ready(160)
	_check(ready.size() == 1 and ready[0] == "alice", "then comes back on schedule")
	_check(not queue.is_waiting("alice"), "and leaves the queue")

	# A target tick, not a countdown: taking twice on the same tick must not produce
	# the same player twice.
	queue.enqueue("bob", 200, 0.5)
	_check(queue.take_ready(240).size() == 1, "one player comes back")
	_check(queue.take_ready(240).is_empty(), "and taking again on the same tick is empty")

	# The order several players come back in decides who gets the good spawn point.
	queue.enqueue_at("zoe", 300)
	queue.enqueue_at("adam", 300)
	queue.enqueue_at("mike", 300)
	var batch := queue.take_ready(300)
	_check(
		batch[0] == "adam" and batch[2] == "zoe",
		"a batch comes back in a deterministic order",
		str(batch)
	)


# --- Spawning --------------------------------------------------------------

func _make_spawns(count: int, spacing: float = 10.0) -> Array[DotSpawnPoint]:
	var out: Array[DotSpawnPoint] = []

	for index in range(count):
		var point := DotSpawnPoint.make(Vector3(float(index) * spacing, 0.0, 0.0))
		point.name = "Spawn%02d" % index
		point.cooldown_ticks = 60
		add_child(point)
		out.append(point)

	return out


func _free_spawns(points: Array[DotSpawnPoint]) -> void:
	for point in points:
		point.queue_free()
		remove_child(point)


func _test_spawn_points() -> void:
	_group("spawn points")

	var point := DotSpawnPoint.make(Vector3(1.0, 2.0, 3.0), 1)
	add_child(point)

	_check(point.is_available(0), "a fresh point is available")
	_check(point.is_available(0, 1), "to its own team")
	_check(not point.is_available(0, 2), "and not to another")

	point.mark_used(100, "alice")
	_check(
		not point.is_available(150, 1),
		"a used point is on cooldown, which is what stops a telefrag"
	)
	_check(point.is_available(300, 1), "and comes back after it")

	point.enabled = false
	_check(not point.is_available(1000, 1), "a disabled point is never offered")

	point.enabled = true
	point.scale = Vector3(3.0, 3.0, 3.0)
	var transform := point.spawn_transform()
	_close(
		transform.basis.get_scale().x,
		1.0,
		"a spawn transform drops the marker's editor scale"
	)

	point.queue_free()
	remove_child(point)


func _test_spawn_selection() -> void:
	_group("spawn selection")

	var points := _make_spawns(5)
	var selector := DotSpawnSelector.new()

	# One enemy standing on the first point. The furthest is the right answer.
	selector.threats = [Vector3.ZERO]
	var chosen := selector.choose(points, 100)
	_check(chosen != null, "a point is chosen")
	_check(
		chosen.name == "Spawn04",
		"the furthest from the nearest threat",
		chosen.name
	)

	# The tie-break. With no threats every point scores identically, and on a
	# symmetric map that is most of them.
	var tie_selector := DotSpawnSelector.new()
	var tie_points := _make_spawns(3)
	var first := tie_selector.choose(tie_points, 1000)
	for point in tie_points:
		point.reset()
	var again := tie_selector.choose(tie_points, 1000)
	_check(
		first.name == again.name,
		"a tie is broken the same way twice",
		"%s vs %s" % [first.name, again.name]
	)

	# Occupied points are skipped entirely, not merely scored badly: spawning there
	# is a telefrag.
	var blocked := DotSpawnSelector.new()
	blocked.threats = [Vector3(40.0, 0.0, 0.0)]
	blocked.blocked_radius = 2.0
	var away := blocked.choose(points, 2000)
	_check(away.name != "Spawn04", "an occupied point is not chosen", away.name)

	# Everything on cooldown: spawning badly beats not spawning at all.
	var busy := DotSpawnSelector.new()
	for point in points:
		point.mark_used(3000)
	var fallback := busy.choose(points, 3001)
	_check(
		fallback != null,
		"with every point on cooldown a player is still spawned somewhere"
	)

	# A team filter that matches nothing must not refuse to spawn.
	for point in points:
		point.team = 1
		point.reset()
	var wrong_team := DotSpawnSelector.new()
	var anyway := wrong_team.choose(points, 4000, 2)
	_check(
		anyway != null,
		"a map whose points are all the other team's still spawns someone"
	)

	_free_spawns(points)
	_free_spawns(tie_points)


# --- Rules -----------------------------------------------------------------

func _test_rules() -> void:
	_group("rules")

	var rules := DotMatchRules.deathmatch(10)
	_check(rules.validate().ok, "a deathmatch ruleset validates")

	var board := DotScoreboard.new()
	add_child(board)

	var alice := board.join("alice", "Alice")
	var bob := board.join("bob", "Bob")

	_check(rules.points_for_kill(alice, bob) == 1, "a kill is worth a point")
	_check(rules.points_for_kill(null, bob) == -1, "a world death costs one")
	_check(rules.points_for_kill(bob, bob) == -1, "and so does a suicide")

	alice.team = 1
	bob.team = 1
	_check(
		rules.points_for_kill(alice, bob) == -1,
		"a team kill costs a point"
	)

	alice.score = 10
	_check(
		rules.round_outcome(board, null, 0.0) == DotMatchRules.Outcome.SCORE,
		"the score limit ends a round"
	)

	alice.score = 0
	_check(
		rules.round_outcome(board, null, 700.0) == DotMatchRules.Outcome.TIME,
		"and so does the clock"
	)
	_check(
		rules.round_outcome(board, null, 0.0) == DotMatchRules.Outcome.NONE,
		"and otherwise it keeps going"
	)

	# A round with no respawning, one round, and no clock never ends and nobody ever
	# comes back. That is a server nobody can leave except by disconnecting.
	var stuck := DotMatchRules.new()
	stuck.respawn_disabled = true
	stuck.rounds_to_win = 1
	stuck.time_limit_sec = 0.0
	stuck.score_limit = 0
	_check(
		not stuck.validate().ok,
		"a ruleset in which a dead player never returns is refused"
	)

	board.queue_free()
	remove_child(board)


# --- Flow ------------------------------------------------------------------

func _test_flow_warmup() -> void:
	_group("flow: warmup")

	var node := _make_match(_quick_rules())
	node.start(0)

	_check(node.state == DotMatch.State.WARMUP, "a match starts in warmup")

	var tick := _advance(node, 1, 300)
	_check(
		node.state == DotMatch.State.WARMUP,
		"and stays there with nobody connected",
		DotMatch.State.keys()[node.state]
	)

	node.add_player("alice", "Alice", tick)
	tick = _advance(node, tick, 200)
	_check(
		node.state == DotMatch.State.WARMUP,
		"and with only one of the two it needs"
	)

	node.add_player("bob", "Bob", tick)
	tick = _advance(node, tick, 120)
	_check(
		node.state != DotMatch.State.WARMUP,
		"then leaves warmup once there are enough",
		DotMatch.State.keys()[node.state]
	)

	tick = _advance(node, tick, 60)
	_check(node.state == DotMatch.State.LIVE, "and the round goes live")
	_check(node.round_number == 1, "as round one")

	# A kill during warmup must not score. Without the check the first player to
	# connect farms the second one before the match starts.
	var warm := _make_match(_quick_rules())
	warm.start(0)
	warm.add_player("alice", "Alice", 0)
	warm.report_kill("alice", "bob", &"rifle", 1)
	_check(
		warm.scoreboard.find("alice").kills == 0,
		"a kill during warmup does not score"
	)
	_check(
		warm.scoreboard.find("bob").deaths == 1,
		"though the death is still real"
	)

	node.queue_free()
	remove_child(node)
	warm.queue_free()
	remove_child(warm)


func _test_flow_deathmatch() -> void:
	_group("flow: a deathmatch to the score limit")

	var node := _make_match(_quick_rules(3))
	node.start(0)
	node.add_player("alice", "Alice", 0)
	node.add_player("bob", "Bob", 0)

	var tick := _advance(node, 1, 150)
	_check(node.state == DotMatch.State.LIVE, "the round is live")

	var respawned: Array[String] = []
	node.respawn_due.connect(
		func(key: String, _s: DotSpawnPoint, _t: int) -> void: respawned.append(key)
	)

	var ended: Array[int] = []
	node.round_ended.connect(
		func(_r: int, winner: int, _o: DotMatchRules.Outcome) -> void:
			ended.append(winner)
	)

	for index in range(3):
		node.report_kill("alice", "bob", &"rifle", tick)
		tick = _advance(node, tick, 40)

	_check(
		node.scoreboard.find("alice").score == 3,
		"three kills reach the score limit",
		str(node.scoreboard.find("alice").score)
	)
	_check(ended.size() == 1, "which ends the round")
	_check(
		node.state == DotMatch.State.MATCH_END,
		"and, in a one-round match, the match",
		DotMatch.State.keys()[node.state]
	)
	_check(
		node.last_outcome() == DotMatchRules.Outcome.SCORE,
		"reporting the score limit as the reason"
	)
	# Two, not three. The third kill reached the score limit, and ending a round
	# clears the respawn queue — a player who died on the round-winning kill must not
	# reappear during the intermission.
	_check(
		respawned.size() == 2,
		"a death during the round respawns, and the one that ends it does not",
		"%d respawns" % respawned.size()
	)

	# The clock.
	var timed := _make_match(_quick_rules(1000))
	timed.rules.time_limit_sec = 2.0
	timed.start(0)
	timed.add_player("alice", "Alice", 0)
	timed.add_player("bob", "Bob", 0)
	var timed_tick := _advance(timed, 1, 150)
	_check(timed.state == DotMatch.State.LIVE, "a timed round starts")
	timed_tick = _advance(timed, timed_tick, 200)
	_check(
		timed.last_outcome() == DotMatchRules.Outcome.TIME,
		"and ends on the clock",
		DotMatchRules.Outcome.keys()[timed.last_outcome()]
	)

	node.queue_free()
	remove_child(node)
	timed.queue_free()
	remove_child(timed)


func _test_flow_rounds() -> void:
	_group("flow: a best-of series")

	var rules := DotMatchRules.team_deathmatch(2)
	rules.warmup_sec = 0.5
	rules.countdown_sec = 0.2
	rules.time_limit_sec = 30.0
	rules.min_players = 2
	rules.rounds_to_win = 2
	rules.intermission_sec = 0.5
	rules.match_end_sec = 0.5
	rules.respawn_delay_sec = 0.2

	var node := _make_match(rules, true)
	node.start(0)
	node.add_player("alice", "Alice", 0, 1)
	node.add_player("bob", "Bob", 0, 2)

	var tick := _advance(node, 1, 80)
	_check(node.state == DotMatch.State.LIVE, "round one is live")

	# Red wins twice.
	for round_index in range(2):
		for kill in range(2):
			node.report_kill("alice", "bob", &"rifle", tick)
			tick = _advance(node, tick, 20)

		_check(
			node.rounds_won.get(1, 0) == round_index + 1,
			"red wins round %d" % (round_index + 1),
			str(node.rounds_won)
		)

		if round_index == 0:
			_check(
				node.state == DotMatch.State.INTERMISSION,
				"and the series continues",
				DotMatch.State.keys()[node.state]
			)
			tick = _advance(node, tick, 80)
			_check(node.state == DotMatch.State.LIVE, "into round two")

	_check(
		node.state == DotMatch.State.MATCH_END,
		"two round wins ends the match",
		DotMatch.State.keys()[node.state]
	)
	_check(node.last_winner() == 1, "with red as the winner")

	# A round reset must zero the scores but keep the teams: reassigning between
	# rounds would shuffle the sides mid-match.
	_check(
		node.scoreboard.find("alice").team == 1,
		"a player keeps their team across a round reset"
	)

	node.queue_free()
	remove_child(node)


func _test_team_assignment() -> void:
	_group("team assignment")

	var node := _make_match(DotMatchRules.team_deathmatch(), true)

	var first := node.add_player("alice", "Alice", 0)
	_check(first.ok, "a player joins")
	_check(
		node.teams.team_of("alice") == 1,
		"and goes on the first team when both are empty"
	)

	node.add_player("bob", "Bob", 0)
	_check(
		node.teams.team_of("bob") == 2,
		"the next goes on the other one",
		str(node.teams.team_of("bob"))
	)

	node.add_player("carol", "Carol", 0)
	_check(
		node.teams.team_of("carol") == 1,
		"and the third evens it up again"
	)

	# A choice that would break the balance is refused rather than accepted and then
	# undone by the balancer, which would switch the player twice in a second.
	var stacked := node.add_player("dave", "Dave", 0, 1)
	_check(
		not stacked.ok,
		"joining the larger team is refused when it would unbalance the sides"
	)

	var allowed := node.add_player("dave", "Dave", 0, 2)
	_check(allowed.ok, "and the other team is fine")

	# A full team.
	node.teams.team(1).max_players = 2
	var full := node.switch_team("dave", 1, 0)
	_check(not full.ok, "a full team refuses a switch")

	node.queue_free()
	remove_child(node)


func _test_balance() -> void:
	_group("autobalance")

	var node := _make_match(DotMatchRules.team_deathmatch(), true)
	node.teams.balance_grace_ticks = 0

	# Build a lopsided game by assigning directly, the way a game that saved teams
	# between maps would.
	for index in range(5):
		node.scoreboard.join("red_%d" % index, "R%d" % index, 1)
	node.scoreboard.join("blue_0", "B0", 2)

	_check(not node.teams.is_balanced(), "five against one is not balanced")

	var moved := node.teams.rebalance(1000)
	_check(moved > 0, "rebalancing moves someone", "%d moved" % moved)
	_check(node.teams.is_balanced(), "until the sides are even")

	# The grace period is the whole reason a player is not switched twice in a row.
	var graced := _make_match(DotMatchRules.team_deathmatch(), true)
	graced.teams.balance_grace_ticks = 600

	for index in range(4):
		graced.teams.assign("red_%d" % index, 1000, 0)

	# Everyone was assigned at tick 1000, so at tick 1100 they are all inside the
	# grace period and nobody may be moved.
	graced.scoreboard.set_team("red_0", 1)
	graced.scoreboard.set_team("red_1", 1)
	graced.scoreboard.set_team("red_2", 1)
	graced.scoreboard.set_team("red_3", 1)

	var during_grace := graced.teams.rebalance(1100)
	_check(
		during_grace == 0,
		"nobody is switched inside the grace period",
		"%d moved" % during_grace
	)

	var after_grace := graced.teams.rebalance(2000)
	_check(after_grace > 0, "and they are once it has passed")

	node.queue_free()
	remove_child(node)
	graced.queue_free()
	remove_child(graced)


func _test_elimination() -> void:
	_group("elimination")

	var rules := DotRulesElimination.make(30.0)
	rules.warmup_sec = 0.2
	rules.countdown_sec = 0.2
	rules.min_players = 2
	rules.intermission_sec = 0.2
	rules.rounds_to_win = 2

	var alive := {"alice": true, "bob": true}
	rules.alive_fn = func(key: String) -> bool: return bool(alive.get(key, false))

	var node := _make_match(rules, true)
	node.start(0)
	node.add_player("alice", "Alice", 0, 1)
	node.add_player("bob", "Bob", 0, 2)

	var tick := _advance(node, 1, 60)
	_check(node.state == DotMatch.State.LIVE, "an elimination round starts")

	alive["bob"] = false
	node.report_kill("alice", "bob", &"rifle", tick)
	tick = _advance(node, tick, 2)

	_check(
		node.last_outcome() == DotMatchRules.Outcome.ELIMINATION,
		"wiping a side ends the round",
		DotMatchRules.Outcome.keys()[node.last_outcome()]
	)
	_check(node.last_winner() == 1, "and the survivors win")

	# A mutual wipe. Zero teams standing must end the round as a draw, not run
	# forever waiting for a side that no longer exists.
	var mutual := _make_match(DotRulesElimination.make(30.0), true)
	(mutual.rules as DotRulesElimination).alive_fn = func(_k: String) -> bool:
		return false
	mutual.rules.warmup_sec = 0.2
	mutual.rules.countdown_sec = 0.2
	mutual.rules.min_players = 2
	mutual.start(0)
	mutual.add_player("alice", "Alice", 0, 1)
	mutual.add_player("bob", "Bob", 0, 2)
	_advance(mutual, 1, 60)
	_check(
		mutual.last_outcome() == DotMatchRules.Outcome.ELIMINATION,
		"a mutual wipe ends the round rather than hanging it"
	)

	# Without alive_fn the ruleset must still terminate, on the clock.
	var unwired := DotRulesElimination.make(1.0)
	unwired.warmup_sec = 0.1
	unwired.countdown_sec = 0.1
	unwired.min_players = 2
	var fallback := _make_match(unwired, true)
	fallback.start(0)
	fallback.add_player("alice", "Alice", 0, 1)
	fallback.add_player("bob", "Bob", 0, 2)
	_advance(fallback, 1, 200)
	_check(
		fallback.last_outcome() == DotMatchRules.Outcome.TIME,
		"an unwired elimination ruleset still ends, on the clock",
		DotMatchRules.Outcome.keys()[fallback.last_outcome()]
	)

	node.queue_free()
	remove_child(node)
	mutual.queue_free()
	remove_child(mutual)
	fallback.queue_free()
	remove_child(fallback)


func _test_kills_outside_live() -> void:
	_group("kills outside a live round")

	var node := _make_match(_quick_rules(3))
	node.start(0)
	node.add_player("alice", "Alice", 0)
	node.add_player("bob", "Bob", 0)

	var tick := _advance(node, 1, 150)
	_check(node.state == DotMatch.State.LIVE, "the round is live")

	for index in range(3):
		node.report_kill("alice", "bob", &"rifle", tick)
		tick = _advance(node, tick, 5)

	_check(node.state == DotMatch.State.MATCH_END, "and ends on the score limit")

	var score_before := node.scoreboard.find("alice").score

	# A kill that lands after the round ended — a rocket already in the air, a
	# bleed-out — must not score, and above all must not re-run the win check on a
	# round that has already ended.
	node.report_kill("alice", "bob", &"rifle", tick)
	_check(
		node.scoreboard.find("alice").score == score_before,
		"a kill after the round has ended does not score"
	)
	_check(
		node.state == DotMatch.State.MATCH_END,
		"and does not disturb the state",
		DotMatch.State.keys()[node.state]
	)

	node.queue_free()
	remove_child(node)


# --- Net sync --------------------------------------------------------------

## A stand-in for the DotNetBehaviour a game writes. Plain properties, because that is
## all [DotMatchNetSync] requires.
class FakeBehaviour extends Object:
	var net_state: int = 0
	var net_round: int = 0
	var net_ends_at: int = 0
	var net_winner: int = 0


func _test_net_sync() -> void:
	_group("net sync")

	_check(DotMatchNetSync.specs().size() == 4, "the bridge describes what replicates")

	var node := _make_match(_quick_rules(3))
	node.start(0)
	node.add_player("alice", "Alice", 0)
	node.add_player("bob", "Bob", 0)
	var tick := _advance(node, 1, 150)

	var behaviour := FakeBehaviour.new()
	DotMatchNetSync.pull(node, behaviour, tick)

	_check(behaviour.net_state == int(DotMatch.State.LIVE), "the state replicates")
	_check(behaviour.net_round == 1, "and the round number")
	_check(behaviour.net_ends_at > tick, "and an absolute end tick")

	# The point of an absolute end tick: a client counts down from a clock it already
	# shares, without the server sending the remaining time every frame.
	var remaining := DotMatchNetSync.seconds_remaining(behaviour, tick, TICK_RATE)
	_close(
		remaining,
		node.seconds_remaining(tick),
		"a client derives the same remaining time the server has",
		0.05
	)

	var later := DotMatchNetSync.seconds_remaining(behaviour, tick + 60, TICK_RATE)
	_close(later, remaining - 1.0, "and it counts down without another packet", 0.05)

	# A state with no clock must report -1 on both sides rather than 0, so a HUD has
	# one branch instead of two.
	node.rules.time_limit_sec = 0.0
	DotMatchNetSync.pull(node, behaviour, tick)
	_check(
		DotMatchNetSync.seconds_remaining(behaviour, tick, TICK_RATE) < 0.0,
		"a round with no clock reports no clock"
	)

	behaviour.free()
	node.queue_free()
	remove_child(node)


func _test_team_spawn_tags() -> void:
	_group("team spawn tags")

	var node := _make_match(DotMatchRules.team_deathmatch(), true)
	node.add_player("alice", "Alice", 0)
	node.add_player("bob", "Bob", 0)

	var red := DotSpawnPoint.make(Vector3(50.0, 0.0, 0.0))
	red.name = "RedSpawn"
	red.tags = [&"red"]
	var blue := DotSpawnPoint.make(Vector3(-50.0, 0.0, 0.0))
	blue.name = "BlueSpawn"
	blue.tags = [&"blue"]
	var anywhere := DotSpawnPoint.make(Vector3(0.0, 0.0, 50.0))
	anywhere.name = "Anywhere"
	for point in [red, blue, anywhere]:
		add_child(point)
		node.add_spawn_point(point)

	node.teams.team(1).spawn_tag = &"red"
	node.teams.team(2).spawn_tag = &"blue"

	var a := node.choose_spawn("alice", 10)
	var b := node.choose_spawn("bob", 10)
	_check(a != null and a.has_tag(&"red"), "team one spawns at its own tag", a.name if a else "none")
	_check(b != null and b.has_tag(&"blue"), "and team two at its own", b.name if b else "none")
	# Much later, so the point bob just took is no longer held against it.
	var named := node.choose_spawn("alice", 5000, &"blue")
	_check(named != null and named.has_tag(&"blue"), "a tag the caller names still wins", named.name if named else "none")

	# No tag means the whole pool, tagged points included: the selector will not
	# refuse a spawn over a mapping detail, and a team game without tags is the
	# ordinary case.
	node.teams.team(1).spawn_tag = &""
	_check(node.choose_spawn("alice", 10) != null, "a team with no tag spawns from the whole pool")

	node.queue_free()
