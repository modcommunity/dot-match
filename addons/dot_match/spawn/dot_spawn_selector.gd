class_name DotSpawnSelector
extends RefCounted

## Picks where a player appears.
##
## The default rule is the one almost every arena shooter uses: **furthest from the
## nearest threat, among the points that are available.** A game that wants something
## else replaces [member danger_fn] or the whole selector.
##
## [b]The tie-break is on the node name, not on iteration order.[/b] Two symmetric
## points on a symmetric map score identically, which on a mirrored arena is most of
## them, and leaving the choice to iteration order makes the spawn depend on the order
## nodes happened to be added — different on a server that built the level from a
## scene and a client that built it from a stream.

const CHANNEL := "match.spawn"

## `func(point: DotSpawnPoint) -> float`. How dangerous a point is; higher is worse.
##
## Left unset, [member threats] is used with a simple nearest-distance rule. Replace it
## to weigh line of sight, recent deaths, or a game mode's own idea of danger.
var danger_fn: Callable = Callable()

## Positions to stay away from. The host refills this before each selection.
##
## Enemies only, and it is the host's job to filter: a selector that spawned people
## away from their own team would scatter a squad across the map.
var threats: Array[Vector3] = []

## Below this many metres a point counts as occupied and is skipped entirely, not
## merely scored badly. Spawning here is a telefrag.
var blocked_radius: float = 1.5

## `func(point: DotSpawnPoint) -> bool`. Extra filter, for a game mode's own rules.
var filter_fn: Callable = Callable()

var _selections: int = 0
var _fallbacks: int = 0


## Chooses a point, or null when there is none at all.
##
## [param for_team] filters by team; 0 accepts any point. [param tag] additionally
## requires it, for a round-start spawn or an attacker spawn.
func choose(
	points: Array[DotSpawnPoint],
	tick: int,
	for_team: int = 0,
	tag: StringName = &""
) -> DotSpawnPoint:
	var best: DotSpawnPoint = null
	var best_score := -INF

	for point in points:
		if point == null or not is_instance_valid(point):
			continue

		if not point.is_available(tick, for_team):
			continue

		if tag != &"" and not point.has_tag(tag):
			continue

		if filter_fn.is_valid() and not bool(filter_fn.call(point)):
			continue

		var danger := _danger_at(point)

		if danger == INF:
			continue

		# Higher is better: distance to the nearest threat, nudged by the point's own
		# weight. The weight is additive rather than multiplicative so a preferred
		# point does not become overwhelmingly preferred on a large map.
		var score := danger + point.weight

		if score > best_score:
			best_score = score
			best = point
		elif is_equal_approx(score, best_score) and best != null and point.name < best.name:
			best = point

	_selections += 1

	if best == null:
		best = _fallback(points, tick, for_team)

	if best != null:
		best.mark_used(tick)

	return best


## Anything at all, ignoring cooldowns and danger.
##
## Reached when every point is on cooldown or occupied, which happens on a small map
## with a full server. **Spawning someone badly beats not spawning them**, and the
## alternative is a player who is dead until a point frees up — which on a busy map
## with a short round is the rest of the match.
func _fallback(
	points: Array[DotSpawnPoint],
	tick: int,
	for_team: int
) -> DotSpawnPoint:
	var candidates: Array[DotSpawnPoint] = []

	for point in points:
		if point == null or not point.enabled:
			continue
		if for_team > 0 and point.team > 0 and point.team != for_team:
			continue
		candidates.append(point)

	if candidates.is_empty():
		# Try again with no team filter before giving up: a map whose points are all
		# tagged for the other team is a mapping mistake, and refusing to spawn is a
		# worse symptom than spawning in the wrong place.
		for point in points:
			if point != null and point.enabled:
				candidates.append(point)

	if candidates.is_empty():
		DotLog.warn(CHANNEL, "no usable spawn point at all", {"tick": tick})
		return null

	_fallbacks += 1

	# The least recently used, ties on name.
	var best: DotSpawnPoint = candidates[0]

	for point in candidates:
		if point.last_used_tick < best.last_used_tick:
			best = point
		elif point.last_used_tick == best.last_used_tick and point.name < best.name:
			best = point

	return best


## Distance to the nearest threat, or INF when the point is occupied.
func _danger_at(point: DotSpawnPoint) -> float:
	if danger_fn.is_valid():
		var value: Variant = danger_fn.call(point)
		return float(value) if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT else 0.0

	if threats.is_empty():
		return 0.0

	var position := point.global_position
	var nearest := INF

	for threat in threats:
		nearest = minf(nearest, position.distance_to(threat))

	if nearest <= blocked_radius:
		return INF

	return nearest


func describe() -> Dictionary:
	return {
		"selections": _selections,
		"fallbacks": _fallbacks,
		"threats": threats.size(),
		"custom_danger": danger_fn.is_valid(),
	}
