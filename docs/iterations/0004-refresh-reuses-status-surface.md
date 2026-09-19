# Iteration: refresh reuses the status surface

## Outcome

Refreshing the status surface now reuses its named buffer instead of attempting
to create a duplicate `currantgit://status` buffer. Buffer-local discovery
updates are also reset cleanly when the surface is reconciled.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` passes, including an explicit `r` refresh assertion.
- Manual: reproduced from the playground after pressing `r`.
- Unverified: preserving folds and cursor position across a future richer
  incremental renderer.

## Drift check

This fixes the lifecycle bug without claiming incremental subtree reconciliation
yet. The current bootstrap still redraws the small status fixture as one
surface.
