# 0007: Conflict detection matches the exact unmerged status-code set

## Context

`parse_status` classified a status entry as a merge conflict with
`status:find("[DAU][DAU]", 1) ~= nil` — a Lua character class matching any
two-character code where both characters are each one of `D`, `A`, or `U`.
That happens to cover all seven real unmerged codes (`DD`, `AU`, `UD`, `UA`,
`DU`, `AA`, `UU`), but it also matches at least one real, *non-conflict*
code built from the same letters: `AD` (staged-add, then deleted from the
worktree — per `git help status`'s short-format table, `[AMD]` in the `Y`
column after `A` in `X` is a legitimate non-conflict state).

This was verified empirically: `git add`-ing a new file and then removing it
from the worktree (without committing or restaging) produces status `AD`.
Under the old check, that file was misclassified as a conflict — placed in
the "Conflicts" section instead of staged+unstaged, with `change_kind =
"conflict"` instead of the correct `"deleted"`.

## Decision

Conflict detection is an explicit lookup against exactly the seven
documented unmerged codes (`DD`, `AU`, `UD`, `UA`, `DU`, `AA`, `UU`), not a
character-class approximation.

## Consequences

- `AD` (and any other coincidental D/A/U combination that isn't a real
  conflict code) is classified correctly and appears in the normal
  staged/unstaged sections instead of a phantom "Conflicts" section.
- Real conflicts are still detected exactly as before — the explicit set is
  a strict subset refinement, not a behavior change for actual conflicts.

## Revisit if

Git adds a new unmerged status code (would need a Git release note change
and a corresponding update to the explicit set — grep for
`UNMERGED_STATUS_CODES`).
