# Iteration: safe discard

## Outcome

Unstaged tracked items now expose `X`. The action asks for explicit
confirmation, leaves the repository untouched on cancellation, and restores
the selected path through Git before refreshing the existing status surface.
Untracked files are intentionally not removed by this action.

## Item/action seam

Discard is available only when the item has a worktree-side status. The item
path is passed as a structured Git argument; no shell command is assembled
from rendered text.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` verifies the cancel path preserves the change and
  the confirmed path removes it from the status snapshot.
- Unverified: hunk-level discard belongs with the shared diff model.

## Drift check

The destructive boundary is explicit in the action itself. It does not use
the generic `:Git` output surface or silently delete untracked files.
