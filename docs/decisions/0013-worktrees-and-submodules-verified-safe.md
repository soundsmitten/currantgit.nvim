# 0013: Worktrees and submodules verified safe as-is

## Context

Audit continuation item 7 was the last unexplored dragon from the main
report: linked worktrees and submodules change what "the repository root"
means (`.git` is a file, not a directory, pointing elsewhere), unlike the
detached-HEAD/unborn-branch cases already covered by decision 0009.

Two disposable fixtures were built and driven through the real UI:

- **Linked worktree** (`git worktree add`): `.git` inside the worktree is a
  file containing `gitdir: <main-repo>/.git/worktrees/<name>`.
  `git rev-parse --show-toplevel` run from inside the worktree correctly
  resolves to the *worktree's own* directory, not the main repository's --
  verified directly, no special handling needed in `repository_root()`.
  Status, diff, and stage were driven through the real `:Git`/`d`/`s`
  mappings from inside the worktree and behaved exactly as they do in an
  ordinary repository; the main repository's own worktree was independently
  confirmed completely unaffected afterward.
- **Submodule** (`git submodule add`): the submodule's own working copy also
  has a `.git` file (`gitdir: ../.git/modules/<name>`). From Git's
  perspective a submodule is a fully independent repository, and
  `repository_root()` treats it as one correctly. Status/diff/stage were
  driven through the real UI from inside the submodule's own directory and
  worked as expected. A submodule with uncommitted changes but an unchanged
  commit pointer showed as `M <name>` in the *parent's* status, but
  attempting to stage it (via CurrantGit or raw `git add`, tested both) is a
  silent no-op -- this was confirmed to be a normal, documented Git
  submodule characteristic (only a changed gitlink is stageable from the
  parent), not a CurrantGit defect. Committing inside the submodule first,
  then staging the resulting gitlink change from the parent, was verified to
  work correctly end-to-end through the real UI.

## Decision

No code change was needed for either case -- `repository_root()`'s existing
`git rev-parse --show-toplevel` call already does the right thing for both,
with no worktree- or submodule-specific logic required anywhere in
CurrantGit. This is recorded as a decision (not left implicit) specifically
so the "dirty submodule can't be staged" behavior isn't mistaken for a bug
and "fixed" by a later agent, and so a future change to `repository_root()`
knows these two cases were independently verified rather than merely
assumed to work by extension of the ordinary-repository case.

Regression coverage: `tests/safety.lua`, `test_linked_worktree`,
`test_submodule`.

## Consequences

- CurrantGit can now claim, with runtime evidence, that it works correctly
  from inside a linked worktree and from inside a submodule's own working
  copy, and that an action inside a linked worktree cannot leak into the
  main repository's own worktree.
- This closes the last item from the original audit's "Remaining dragons"
  list that had not yet been independently exercised end-to-end.

## Revisit if

A future feature adds any cross-worktree or cross-submodule awareness (e.g.
listing all linked worktrees, or recursing into submodules from the parent's
status view) -- that is new functionality this record does not cover, and
would need its own fixtures and verification rather than assuming this
record's "no special handling needed" conclusion extends to it.
