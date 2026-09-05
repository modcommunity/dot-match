@tool
class_name DotTeam
extends Resource

## One side. A description; the score and the roster live in [DotTeamManager].
##
## [b]Team ids start at 1.[/b] Zero means "no team" throughout dot-match and
## dot-combat, and two players with no team are never allies — a free-for-all in which
## everyone compares as team 0 would be a mode where nobody can damage anybody.

## Zero is reserved. Use 1 and up.
@export_range(1, 32, 1) var id: int = 1

@export var display_name: String = ""

## Short label for a HUD and a kill feed. Two or three characters.
@export var abbreviation: String = ""

@export var colour: Color = Color.WHITE

@export_group("Capacity")

## Most players allowed. Zero means unlimited, bounded only by the server.
@export_range(0, 128, 1) var max_players: int = 0

@export_group("Spawning")

## Spawn points tagged with this belong to this team. Empty means the whole pool,
## tagged points included. Read by [method DotMatch.choose_spawn].
@export var spawn_tag: StringName = &""

@export_group("Role")

## Not a playing side. Spectators, and a "waiting to join" holding pen.
##
## Excluded from balance, from win conditions and from the scoreboard's player count,
## which is four different places that would each otherwise need a special case.
@export var is_spectator: bool = false


static func make(
	p_id: int,
	p_name: String,
	p_colour: Color = Color.WHITE
) -> DotTeam:
	var team := DotTeam.new()
	team.id = p_id
	team.display_name = p_name
	team.abbreviation = p_name.substr(0, 3).to_upper()
	team.colour = p_colour
	return team


## The two sides almost every team mode starts from.
static func standard_pair() -> Array[DotTeam]:
	return [
		DotTeam.make(1, "Red", Color(0.85, 0.25, 0.25)),
		DotTeam.make(2, "Blue", Color(0.25, 0.45, 0.9)),
	]


static func spectators(p_id: int = 31) -> DotTeam:
	var team := DotTeam.make(p_id, "Spectators", Color(0.6, 0.6, 0.6))
	team.is_spectator = true
	return team


func validate() -> DotResult:
	if id <= 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Team ids start at 1; 0 means 'no team' everywhere in this family."
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"id": id,
		"name": display_name,
		"abbreviation": abbreviation,
		"max": max_players,
		"spectator": is_spectator,
	}


func _to_string() -> String:
	return "DotTeam(%d %s)" % [id, display_name]
