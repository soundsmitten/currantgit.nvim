# Iteration: always-on action list, `g?` opens `:help`

## Outcome

The status and log surfaces always end with an "Available actions" list
(contextual key + description, keys padded so descriptions share a column)
in place of the one-line `Actions:` bar that `g?` used to expand. `g?` now
opens the surface's real help section (`:help currantgit-status` /
`:help currantgit-log`). When no `doc/tags` exists yet (a bare `rtp`
checkout), CurrantGit runs `:helptags` on its own `doc/` once and retries.

`doc/currantgit.txt`'s CONTENTS block redefined several section tags
(`*currantgit-status*` and others appeared twice), which makes `:helptags`
fail with E154. They are now `|links|`.

## Evidence

- Test-first: the rewritten smoke/log assertions failed against the old
  footer (no "Available actions" until `g?` was pressed).
- Automated: list present without `g?`, no `Actions:` bar, aligned
  description column, list outside folds, cursor-in-list does not rewrite
  it, `g?` lands on `*currantgit-status*` / `*currantgit-log*`, closing help
  returns to the originating window, and the log list never offers mutations.
- Manual: how the list reads against a real colorscheme is still for human
  review.

## Drift check

Projection-only: no Git command, action ID, or registry contract changed.
The `CurrantGitAction` highlight group is gone along with the bar it styled.
