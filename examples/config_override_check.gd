extends Node

## DotMatchConfig's rule overrides, offline. With dot-game, dot-profile and dot-server linked into addons/ (gitignored) it also runs them through DotGameConfigBinder's cvars.
##
## [codeblock]
## godot --headless --path . res://examples/config_override_check.tscn
## [/codeblock]

const TICK_RATE := 60
const BINDER := "res://addons/dot_game/runtime/dot_game_config_binder.gd"
const CONVAR := "res://addons/dot_server/console/dot_convar.gd"
const CHECKS_BASE := 10
const CHECKS_BINDER := 8

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])


func _make(rules: DotMatchRules) -> DotMatch:
	var node := DotMatch.new()
	node.register_service = false
	node.rules = rules
	node.config = DotMatchConfig.new()
	node.config.tick_rate = TICK_RATE
	node.config.auto_start = false
	node.config.log_transitions = false
	node.config.idle_seconds = 0.0
	var manager := DotTeamManager.new()
	manager.teams = DotTeam.standard_pair()
	node.teams = manager
	node.add_child(manager)
	add_child(node)
	return node


func _live(node: DotMatch) -> int:
	node.start(0)
	node.add_player("a", "A", 1)
	node.add_player("b", "B", 1)
	node.add_player("c", "C", 2)
	var tick := 1
	while node.state != DotMatch.State.LIVE and tick < 600:
		node.tick(tick)
		tick += 1
	node.scoreboard.set_team("a", 1)
	node.scoreboard.set_team("b", 1)
	node.scoreboard.set_team("c", 2)
	return tick


func _rules() -> DotMatchRules:
	var rules := DotMatchRules.team_deathmatch(50)
	rules.warmup_sec = 1.0
	rules.countdown_sec = 0.5
	rules.min_players = 2
	rules.respawn_delay_sec = 3.0
	rules.friendly_points = -1
	return rules


func _run() -> void:
	print("dot-match: config rule overrides")
	var code := 0
	var node := _make(_rules())
	var tick := _live(node)
	_check(node.state == DotMatch.State.LIVE, "match goes live")
	_check(not DotMatchOverrides.respawn_off(node.config, node.rules), "defaults defer to the rules: respawn on")
	_check(is_equal_approx(DotMatchOverrides.respawn_delay(node.config, node.rules, null), 3.0), "defaults defer to the rules: delay")
	_check(DotMatchOverrides.friendly_points(node.config, node.rules) == -1, "defaults defer to the rules: friendly points")

	node.config.respawn_delay_sec = 1.0
	node.config.friendly_points = -7
	var before: Variant = node.scoreboard.find("a").score
	node.report_kill("a", "b", &"rifle", tick)
	_check(node.scoreboard.find("a").score == before - 7, "friendly_points override sets the team-kill penalty")
	_check(absf(node.respawns.seconds_remaining("b", tick) - 1.0) < 0.05, "respawn_delay_sec override sets the wait")

	node.config.respawn_disabled = 1
	node.report_kill("c", "a", &"rifle", tick + 1)
	_check(not node.respawns.is_waiting("a"), "respawn_disabled = 1 queues no respawn")
	node.config.respawn_disabled = 0
	node.rules.respawn_disabled = true
	_check(not DotMatchOverrides.respawn_off(node.config, node.rules), "respawn_disabled = 0 beats a rules-level off")
	node.config.respawn_disabled = -1
	_check(DotMatchOverrides.respawn_off(node.config, node.rules), "-1 returns to the rules' off")
	_check(node.config.validate().ok, "the config validates")
	node.queue_free()

	var script: Script = load(BINDER) if FileAccess.file_exists(BINDER) and FileAccess.file_exists(CONVAR) else null
	var expected := CHECKS_BASE
	if script == null:
		print("  skip  cvar binding: dot-game is not linked")
	else:
		expected += CHECKS_BINDER
		_binder(script)

	print("%d passed, %d failed" % [_passed, _failed])
	if _passed + _failed != expected:
		print("ERROR: %d checks ran, %d expected" % [_passed + _failed, expected])
		code = 1
	get_tree().quit(1 if _failed > 0 or code != 0 else 0)


func _binder(script: Script) -> void:
	var node := _make(_rules())
	var tick := _live(node)
	var binder: Object = script.call("create", node.config, "match", "mp")
	var made: Array = binder.call("bind_cvars", _add_cvar, 1)
	var delay: Object = binder.call("cvar_for", "respawn_delay_sec")
	var off: Object = binder.call("cvar_for", "respawn_disabled")
	var friendly: Object = binder.call("cvar_for", "friendly_points")
	_check(made.size() >= 3 and delay != null and off != null and friendly != null, "binder makes the three cvars")
	_check(delay.get("name") == "mp_respawn_delay_sec" and friendly.get("name") == "mp_friendly_points", "named mp_<field>")
	_check(delay.call("set_value", "2.0").ok and is_equal_approx(node.config.respawn_delay_sec, 2.0), "setting the delay cvar writes the config")
	_check(friendly.call("set_value", "-4").ok and node.config.friendly_points == -4, "setting the friendly cvar writes the config")
	var before: Variant = node.scoreboard.find("a").score
	node.report_kill("a", "b", &"rifle", tick)
	_check(node.scoreboard.find("a").score == before - 4, "the next team kill uses the cvar")
	_check(absf(node.respawns.seconds_remaining("b", tick) - 2.0) < 0.05, "the next respawn uses the cvar")
	_check(off.call("set_value", "1").ok and node.config.respawn_disabled == 1, "setting the respawn cvar writes the config")
	_check(not off.call("set_value", "5").ok and node.config.respawn_disabled == 1, "an out-of-set value is refused")
	node.queue_free()


func _add_cvar(cvar_name: String, value: String, description: String, flags: int) -> Object:
	return (load(CONVAR) as GDScript).new(cvar_name, value, description, flags)
