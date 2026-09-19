# Iteration: repository-first header

## Outcome

The default status header now identifies the repository directly. The plugin
name is no longer repeated in every surface; a custom title remains available
as an explicit configuration choice.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` asserts the default header omits `CurrantGit`.
- Unverified: custom title styling in a manually themed Neovim session.

## Drift check

This is a presentation correction only. It does not change item identity,
actions, or the surface lifecycle.
