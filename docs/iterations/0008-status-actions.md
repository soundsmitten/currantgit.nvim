# Iteration: status staging actions

## Outcome

Status items now expose real Git index actions. `s` stages the current file,
`u` unstages it, and `-` toggles the staged state. Each action refreshes the
existing status surface after Git completes.

## Item/action seam

Action availability is derived from the item's two-column Git status. The
action operates on the item's path, never on a rendered line number. The
discovery bar and mappings use the same registry entries.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` creates a staged file, stages a modified file,
  unstages it, and verifies the resulting Git status through the mapped keys.
- Unverified: hunk-level staging and discard safety belong to later slices.

## Drift check

The action uses Git's modern `add` and `restore --staged` commands through the
same asynchronous execution seam. It does not open a command-output buffer or
silently invent a second status model.
