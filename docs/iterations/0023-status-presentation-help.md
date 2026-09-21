# Iteration: compact status presentation and inline help

## Outcome

Status rows now use compact `M path` presentation, semantic regions receive
colorscheme-friendly CurrantGit highlight groups, and `g?` toggles contextual
help as searchable, yankable buffer text instead of a transient notification.

## Item/action seam

Status rendering emits highlight spans alongside its semantic line-item and
fold projections. Discovery and expanded help both derive from the existing
action registry; help lines do not become item identity.

## Evidence

- Test-first: the clean headless interaction failed first on the old indented
  status row.
- Automated: `scripts/test` covers compact rows, expected highlight groups,
  refresh without duplicate highlights, inline-help toggle behavior, semantic
  item targeting, native folds, and existing status actions.
- Manual: colorscheme appearance and the feel of opening/closing help remain
  to be checked interactively.

## Drift check

This changes only the status projection and its help presentation. Git
execution, mutations, diff/log/blame content, and the action registry contract
remain unchanged.
