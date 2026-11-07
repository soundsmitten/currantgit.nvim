# Iteration: finishing a conflict from status (issue 0010, slice 3)

## Outcome

- Status shows the operation in progress under the branch: `Rebasing side
  onto 1a2b3c4 (2/3)`, `Merging 9f8e7d6`, `Cherry-picking …`, `Reverting
  …`. lua/currantgit/operation.lua reads the git dir the way Git's
  `git-prompt.sh` does; the git dir comes from `rev-parse --absolute-git-dir`
  (cached per root) so linked worktrees see their own state.
- `rr`/`rs`/`ra` continue, skip and abort it (fugitive's rebase keys,
  extended to merge, cherry-pick and revert). They are mapped only while an
  operation is in progress, so `r` never waits on 'timeoutlen'. Merge has no
  `rs`. `ra` confirms. Each key re-reads the operation and refuses if it is
  no longer the one status shows.
- `s` and `-` mark a conflicted file resolved, but refuse while the file on
  disk has a marker line at its `conflict-marker-size`, or unsaved edits.
  Visual `s`/`-` include conflict rows (they were silently dropped) and name
  what they skip.
- `R` recreates a text conflict with `git checkout -m`, after confirming.

## Bugs found

- Already on main: `-` on a conflict row ran `git restore --staged`, which
  Git accepts on an unmerged path and which replaces all three stages with
  HEAD's version (docs/gotchas.md). The test that shows it failed on the old
  code; `-` on a conflict row now only stages.
- Already on main: Visual mode ignored conflict rows entirely.
- Found by the adversarial pass: the first marker guard assumed 7-character
  markers, so `conflict-marker-size=9` let a file with markers be staged.
  The guard now asks `git check-attr`; regressions cover sizes 9 and 5.

## Evidence

- Test-first: tests/e2e/operations.lua (15 scenarios) failed on the unfixed
  code and passes.
- Adversarial (tests/e2e/operations_edges.lua, 10 scenarios): marker sizes 9
  and 5, CRLF markers, a Markdown `=======` heading (must not block), a path
  with spaces, unicode and a leading dash for `s` and `R`, a merge in a linked
  worktree (shown there only), the `--apply` rebase backend, an operation
  changed outside Neovim (`ra` refuses), a multi-commit cherry-pick skipped
  then continued, `R` on a delete/modify row (not offered, nothing changes),
  untracked files surviving `ra`.
- Contracts checked against real Git 2.50.1 before relying on them: state
  files per operation, `--continue/--skip/--abort` for each, no `merge
  --skip`, `check-attr -z` format and literal path handling.
- Not covered: `git am` and bisect (not recognized, documented), the
  `rebase-apply` `onto` file on older Git, Neovim other than 0.12.4, and the
  look of the header on screen. `rr`/`rs`/`ra` are documented, but the help
  coverage check cannot see them (the smoke run has no operation in
  progress).
