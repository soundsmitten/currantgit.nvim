# Iteration: safe public action projections

## Outcome

Public `discovery()` and `which_key()` calls now return an empty table instead
of throwing when an integration invokes them outside a CurrantGit buffer or
with an invalid buffer ID.

## Item/action seam

The action registry is unchanged. The public projection boundary now verifies
that the target buffer has CurrantGit line-item metadata before resolving the
item under the cursor or constructing an action context.

## Evidence

- Test-first: the ordinary-buffer regression failed against the unfixed code
  with a nil-index error in `current_item()`.
- Automated: the clean headless smoke path covers `discovery()` and
  `which_key()` for ordinary, invalid, and CurrantGit status buffers.

## Drift check

This does not broaden action availability, add mappings, or change repository
state. CurrantGit surfaces continue deriving projections from the shared action
registry.
