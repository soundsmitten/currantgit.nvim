# 0001: Buffer-scoped Git actions reuse the buffer's captured root

## Context

Every CurrantGit buffer (status, diff, log, commit, blame) stores the
repository root it was opened against in `vim.b[buffer].currantgit_root`.
Actions dispatched from that buffer — stage, unstage, discard, hunk
stage/unstage, diff, blame, open, refresh — used to call `repository_root()`
again at the moment the action actually ran, which re-derives the root from
Neovim's live, global working directory instead of the buffer's own root.

Stage, unstage, discard, and hunk actions are asynchronous: they run a Git
process and, for discard, also wait on `vim.ui.select` for confirmation. If
the user (or a script) changes the editor's working directory during that
async gap, the action would run its Git mutation against whatever repository
the *cwd* now points at, using a pathspec that only made sense relative to
the *original* repository.

This was verified empirically: staging a `:cd` into a second repository
during the `vim.ui.select` confirmation gap of a discard on the first
repository silently discarded an unrelated uncommitted change in the second
repository.

## Decision

Any action dispatched from an existing CurrantGit buffer uses that buffer's
captured `root`, never a fresh `repository_root()` call. `repository_root()`
is still used, but only as a *fallback* for entry points that have no buffer
context yet (the top-level `:Git`, `:GitActivity` command dispatch). The
fallback shape is: accept an optional `root` parameter, and only resolve it
fresh when the caller didn't already know one.

`open_log` and `open_commit` already followed this pattern before the audit
and were used as the reference implementation. `open_status`, `open_diff`,
`open_diff_args`, `open_deleted`, and `open_blame` were brought in line with
it.

## Consequences

- A CurrantGit surface's identity — and anything you do from it — is now
  pinned to the repository it was opened against, independent of ambient
  editor state (cwd, other tabs, other windows).
- Refreshing a surface (`r`) also stays pinned to its own repository instead
  of picking up whatever `getcwd()` currently resolves to.
- The one place root is still resolved fresh on every call is genuinely
  top-level command dispatch (`:Git ...`, `:GitActivity`), where "operate on
  whatever repository the current directory points at" is the correct,
  Fugitive-like behavior — there is no existing buffer identity to preserve.

## Revisit if

A future surface is added that has an intentionally dynamic root (unlikely —
prefer opening a new surface over silently retargeting an existing one). If
that need appears, it should be an explicit, visible action, not an implicit
side effect of the editor's cwd changing underneath a buffer.
