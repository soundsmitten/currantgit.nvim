# 0009: Bare repositories, detached HEAD, and unborn branches verified safe as-is

## Context

The original audit's "Remaining dragons" flagged bare repositories, detached
HEAD, and unborn/zero-commit branches as never having been exercised
end-to-end through actual CurrantGit buffers. The doctrine is explicit that
"should be fine" is not evidence — this had to be built and observed, not
reasoned about.

Three disposable fixtures were built and driven through `:Git status`,
`:Git log`, `:Git diff`, and `:Git blame` (where applicable):

- **Bare repository** (`git init --bare`): `git rev-parse --show-toplevel`
  itself fails (`fatal: this operation must be run in a work tree`, exit
  128) inside a bare repo. `repository_root()` already surfaces that as a
  clean `nil, error_message` before `open_status`/`open_log`/`open_diff` ever
  attempt a Git operation against it — there is no separate "is this bare"
  check anywhere, and none was needed. Verified: no buffer is created or
  switched to, no crash, one clear notification per attempted command.
- **Detached HEAD**: `git status --porcelain=v1 -z --branch` emits
  `## HEAD (no branch)` as a normal, valid branch header. `parse_status`
  already passes it through unmodified as the branch display string. Status
  render and diff both work exactly as they do on a normal branch — verified
  with a real detached checkout and a real working-tree edit.
- **Unborn branch** (`git init` with zero commits): status emits
  `## No commits yet on <branch>`, also passed through unmodified and
  rendered correctly, including a real untracked file showing up in the
  Untracked section. `git log` and `git blame` both fail with a real,
  expected Git error (no HEAD to resolve yet); `git diff` against the empty
  index/worktree just succeeds with empty output. All three come back as
  clean notifications or unremarkable empty results, never a crash.

## Decision

No code change was needed for any of these three cases — they were already
handled correctly by the existing `repository_root()` failure path (bare) and
by treating the branch header as an opaque display string (detached/unborn).
This is recorded as a decision, not left as an implicit assumption, so a
later agent doesn't waste time re-adding bare-repo detection or
detached/unborn special-casing that would be redundant.

Regression coverage: `tests/safety.lua`,
`test_bare_repository_refuses_cleanly`, `test_detached_head`,
`test_unborn_branch`.

## Consequences

- CurrantGit can now claim, with runtime evidence, that a bare repository
  refuses cleanly (no crash, no phantom surface) and that detached HEAD and
  an unborn branch both render and behave correctly for status/diff, with
  log/blame failing as clean, expected Git errors on an unborn branch.
- This does **not** cover worktrees or submodules (audit continuation item
  7, still open) — those change what "the repository root" *means*, unlike
  these three cases, which only change what HEAD/the branch/the commit
  history look like.

## Revisit if

A future change touches `repository_root()`, `parse_status`'s branch-header
handling, or adds any bare-repo-specific logic — re-verify against real Git
fixtures rather than assuming this record still holds, per the doctrine that
an earlier agent's verification is evidence, not settled fact.
