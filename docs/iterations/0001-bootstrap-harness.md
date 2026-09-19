# Iteration: bootstrap harness

## Outcome

CurrantGit can now open a minimal status surface through `:Git` in a clean
headless Neovim process. The surface renders a real temporary Git fixture and
exposes change items for modified and untracked files.

## Item/action seam

- `change` items have stable IDs, change kinds, paths, status, and capabilities.
- `:Git` and `:Git status` resolve to the status projection.
- Git execution is isolated behind the first small executor seam in the Lua
  bootstrap.

## Evidence

- Automated: `scripts/test` passes.
- Automated: `scripts/validate` passes.
- Automated: clean Neovim v0.12.5 smoke path passes with isolated XDG state and
  unrelated plugins disabled.
- Unverified: interactive folds, staging, blame, diff composition, and native
  desktop actions.

## Drift check

This slice deliberately does not implement the full status renderer, action
registry, blame surface, or RPC gateway. Those remain separate stages rather
than being implied by the bootstrap command.
