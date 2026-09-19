# Iteration: semantic status actions

## Outcome

The bootstrap status surface now resolves contextual actions from semantic
change items. `r` refreshes, `g?` explains the surface, `<CR>` opens the item,
and `d` requests its diff. The discovery line is generated from the same action
registry as the mappings.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` passes against modified and untracked fixture items.
- Unverified: staging, full diff rendering, folds, blame, and interactive visual
  polish.

## Drift check

The action registry is intentionally small. It does not yet pretend to be the
full plugin system, and no staging, RPC, or external-provider behavior was
pulled into this slice.
