# Iteration: commit from status, with Git's editor in Neovim

## Outcome

Status has fugitive's commit keys: `cc`, `ca`, `ce`, `cw`, `cvc`, `cva`.
More broadly, any Git command CurrantGit runs that wants an editor now gets
one here: `:Git commit`, `:Git merge`, `:Git tag -a`, `:Git rebase -i`.
Before, Git launched whatever editor it found with no terminal, and the
commit failed ("Aborting commit due to empty commit message").

The async executor sets `GIT_EDITOR`/`GIT_SEQUENCE_EDITOR` to
`lua/currantgit/git_editor_shim.lua`, run by a `--clean` headless Neovim.
The shim asks the running Neovim (`CURRANTGIT_SERVER`) to open the file in a
split and polls until that buffer is wiped. Git writes the template and reads
the result, so merge messages, `commit.template`, `-v`, hooks and Git's
empty-message abort all behave as in a terminal. See decisions/0015.

Also in this slice: `:Git` commands mark status stale (it refreshes on the
next enter); writes to files under `.git/` don't; `action()` failures fall
back to stdout when Git writes its refusal there ("nothing to commit"); and
the e2e harness fails instead of hanging when the child is blocked on input.

## Evidence

- Test-first: the 10 scenarios in tests/e2e/commit.lua timed out against the
  unfixed code and pass now.
- Adversarial pass (separate fixtures, verdicts from real Git): a repo path
  with spaces, a quote, unicode and a leading dash; a plugin installed under
  a path with a quote; a linked worktree; an unborn branch (`ca` refused by
  Git, `cc` makes the root commit); nothing staged (no editor opens);
  rejecting pre-commit and commit-msg hooks; `COMMIT_EDITMSG` already open
  and modified (refused, draft untouched); quitting Neovim mid-edit (Git
  aborts, no stale `index.lock`, no stray shim); two editors at once;
  `commit.template`.
- It found one bug: a CurrantGit view opening in the message window (for
  example the output of a second `:Git` command) replaced and wiped the
  message buffer, ending the edit and aborting the commit. Views now open in
  a split from that window. Regression: "a CurrantGit view opened from the
  message window leaves the edit running". The edge cases are kept as
  tests/e2e/commit_edges.lua.
- Unexplained: one full adversarial run failed the two-editor case at an
  editor wait. It did not recur in six further runs (three alone, three full);
  the scenario now prints window and mode diagnostics if it happens again.
- Not covered: a TCP `--listen` server address (the shim supports it, untested),
  Windows, Neovim other than 0.12.4.
