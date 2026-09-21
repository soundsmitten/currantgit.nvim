# Issue 0009: Keep public action projections safe outside CurrantGit buffers

## Status

Implemented — focused regression green.

## Observed failure

The adversarial audit called `require("currantgit").discovery()` and
`which_key()` from an ordinary buffer. Both reached `current_item()`, indexed
an unset `b:currantgit_line_items`, and raised a Lua nil-index error.

## Required behavior

- Public action projections return an empty table for ordinary and invalid
  buffers.
- CurrantGit surfaces retain their existing contextual projection behavior.
- The guard belongs at the public projection boundary; callers should not need
  to duplicate private buffer-detection rules.

## Evidence

The clean headless interaction test calls both public functions against an
ordinary buffer and an invalid deleted buffer. The ordinary-buffer assertion
failed against the unfixed code with the audit's nil-index error and passes
with the boundary guard.
