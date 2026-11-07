class_name DotMatchOverrides
extends RefCounted

## Where [DotMatchConfig]'s rule overrides win over the [DotMatchRules]; read at use, so a cvar change is live.


## True when nobody respawns until the round ends.
static func respawn_off(config: DotMatchConfig, rules: DotMatchRules) -> bool:
	if config.respawn_disabled >= 0:
		return config.respawn_disabled == 1
	return rules.respawn_disabled


## Seconds before [param victim] respawns; null is a joiner.
static func respawn_delay(config: DotMatchConfig, rules: DotMatchRules, victim: DotPlayerScore) -> float:
	if config.respawn_delay_sec >= 0.0:
		return config.respawn_delay_sec
	return rules.respawn_delay(victim) if victim != null else rules.respawn_delay_sec


## Points for a team kill.
static func friendly_points(config: DotMatchConfig, rules: DotMatchRules) -> int:
	return config.friendly_points if config.friendly_points >= -100 else rules.friendly_points
