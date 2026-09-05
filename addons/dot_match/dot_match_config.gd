@tool
class_name DotMatchConfig
extends DotConfig

## Everything configurable about the match loop that is not a game mode's rules.
##
## The split matters: [DotMatchRules] is what the mode is, and swapping it changes the
## game. This is how the server runs it, and it is the same regardless of mode.
##
## Layered like every [DotConfig]: exported defaults, then a JSON file, then
## [code]DOT_MATCH_*[/code] environment variables, then [code]--match-*[/code]
## arguments.

@export_group("Simulation")

## Must match whatever drives [method DotMatch.tick]. Every duration in the rules is
## converted against it.
@export_range(1, 240, 1) var tick_rate: int = 64

@export_group("Flow")

## Start warmup as soon as the match node is ready.
@export var auto_start: bool = true

@export_group("Balance")

## Rebalance the teams at the start of each round.
##
## [b]At round start, not continuously.[/b] Switching someone mid-fight takes a player
## who was winning a duel and puts them on the other side of it.
@export var balance_between_rounds: bool = true

@export_group("Idle")

## Seconds of doing nothing before a player is considered idle. Zero disables it.
##
## dot-match only marks them: what to do about it — a warning, a move to spectators, a
## kick — is a server policy and belongs in dot-server.
@export_range(0.0, 3600.0, 30.0) var idle_seconds: float = 180.0

@export_group("Diagnostics")

## Log every state transition at info level. Cheap, and the first thing anyone wants
## when a match is stuck in a state nobody expected.
@export var log_transitions: bool = true


func env_prefix() -> String:
	return "DOT_MATCH_"


func cli_prefix() -> String:
	return "--match-"


func validate() -> DotResult:
	if tick_rate <= 0:
		return DotResult.fail(DotError.CODE_INVALID, "tick_rate must be positive.")

	return DotResult.success(null)


func describe_summary() -> String:
	return "%d Hz%s" % [
		tick_rate,
		"" if balance_between_rounds else ", no autobalance",
	]
