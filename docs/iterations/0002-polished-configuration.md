# Iteration: polished configuration

## Outcome

CurrantGit now has a small, validated configuration surface with useful
defaults. `setup({})` is enough for the common path; nested options can tune the
Git executable, title, branch/count/clean metadata, and status icons.

## Item/action seam

Configuration changes the projection without changing item identity. Status
items remain semantic `change` objects while the renderer chooses their visible
icon and surrounding metadata.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` passes with the configured status surface.
- Unverified: user-customized icons and alternate Git executable paths in a
  non-default environment.

## Drift check

No renderer internals are exposed as options. New configuration should earn its
place by changing observable product behavior and receiving a focused test.
