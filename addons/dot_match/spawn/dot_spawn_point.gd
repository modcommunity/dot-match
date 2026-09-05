@tool
class_name DotSpawnPoint
extends Node3D

## One place a player can appear.
##
## A marker with a team, some tags and a cooldown. It does no selection of its own —
## that is [DotSpawnSelector], because choosing between points needs to see all of
## them and the danger around each.

## Which team may use it. Zero means anyone.
@export_range(0, 32, 1) var team: int = 0

## Free-form tags a game mode filters on: `attackers`, `round_start`, `vip`.
@export var tags: Array[StringName] = []

## Off means the point is not offered at all. For a point inside a door that is shut,
## or a zone the round has not opened yet.
@export var enabled: bool = true

## Ticks after use before this point is offered again.
##
## The reason it exists is telefragging: two players spawning on the same point within
## a few ticks appear inside each other. A cooldown of a couple of seconds costs
## nothing on a map with enough points and prevents it entirely.
@export_range(0, 600, 5) var cooldown_ticks: int = 120

## Preference weight. Higher points are chosen first when danger scores are equal.
@export_range(0.0, 10.0, 0.1) var weight: float = 1.0

## Tick this point was last spawned on. -1 when never.
var last_used_tick: int = -1

## Who used it last, for diagnostics.
var last_user: String = ""


static func make(position: Vector3, team_id: int = 0) -> DotSpawnPoint:
	var point := DotSpawnPoint.new()
	point.position = position
	point.team = team_id
	return point


## Whether this point may be used by [param for_team] on [param tick].
func is_available(tick: int, for_team: int = 0) -> bool:
	if not enabled:
		return false

	if team > 0 and for_team > 0 and team != for_team:
		return false

	if last_used_tick >= 0 and tick - last_used_tick < cooldown_ticks:
		return false

	return true


func has_tag(tag: StringName) -> bool:
	return tags.has(tag)


func mark_used(tick: int, user: String = "") -> void:
	last_used_tick = tick
	last_user = user


func reset() -> void:
	last_used_tick = -1
	last_user = ""


## Where a player actually appears, and facing which way.
##
## The point's own transform, with the scale dropped: a spawn marker scaled in the
## editor for visibility would otherwise scale the player placed on it.
func spawn_transform() -> Transform3D:
	return Transform3D(global_transform.basis.orthonormalized(), global_position)


func describe() -> Dictionary:
	return {
		"node": name,
		"team": team,
		"tags": Array(tags),
		"enabled": enabled,
		"last_used": last_used_tick,
	}


func _to_string() -> String:
	return "DotSpawnPoint(%s, team %d)" % [name, team]
