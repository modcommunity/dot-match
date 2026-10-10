# History

Bugs worth recognising if they come back. The lessons that still apply are in [design.md](design.md).

## `pause_when_empty` was read off the wrong object

`pause_when_empty` was declared on `DotMatchRules` and read off `DotMatchConfig`. It parsed cleanly, and the match sat in `COUNTDOWN` forever; nothing but running a round would have found it, which the self-test now does. The fix put the threshold and the decision on the same object (the rules), and removed `DotMatchConfig.run_when_empty`, which overlapped it and which nothing read.

## A game cleared `spawn_points()` by reference

game-g2gfast cleared the array `spawn_points()` returns on every map load. It worked only because the return was not a copy. `remove_spawn_point` and `clear_spawn_points` were added so nobody has to mutate the returned array, and g2gfast now calls `clear_spawn_points()`.
