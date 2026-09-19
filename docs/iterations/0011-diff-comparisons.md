# Iteration: diff comparisons

## Outcome

`:Git diff` and `:Git diff --cached` now render through the same read-only diff
surface used by the status `d` action. Git arguments remain the comparison
specification; the renderer and hunk folding do not fork by entry point.

## Item/action seam

The diff surface accepts an argument vector, not a shell string. That leaves
room for revision comparisons while preserving Git's normal path and revision
parsing rules.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` verifies the staged comparison identifies
  `staged.txt` and returns to the status projection afterward.
- Unverified: split presentations and arbitrary revision UX are later slices.

## Drift check

The `:Git` escape hatch and semantic item action share one diff parser and one
buffer projection. No second command-output renderer was introduced.
