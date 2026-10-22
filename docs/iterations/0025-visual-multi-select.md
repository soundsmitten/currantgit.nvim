# Iteration: visual-mode multi-select actions

## Outcome

Closes the Fugitive parity gap for multi-select staging. In the status
buffer, visual `s`/`u`/`-`/`X` act on every unique item across the selected
lines; in the diff surface (and in status inline `=` diffs), visual `s`/`u`
act on every selected hunk. Files go to Git as one `git add` /
`git restore --staged` / `git restore --worktree` call with one
`:(literal)` pathspec per file; `X` confirms once and lists every file.
Hunks are concatenated into one patch for
`git apply --cached [--reverse] --unidiff-zero`, so the batch is atomic.

Also fixes a bug: normal `s`/`u` on a hunk inside a status inline diff
dispatched `item.stage`/`item.unstage` (and so did nothing but warn).
They now resolve per item kind through `dispatch_current_key`, and a hunk
action in status refreshes status instead of calling `open_diff_args` with
the status buffer's (nil) diff args.

## Item/action seam

No new registry actions or public IDs. The visual path reads
`b:currantgit_line_items` for the selected lines, dedupes (files by path,
hunks by mode + patch, because inline diffs of different files each number
hunks from 1), and filters each item through the same `is_available`
predicates as the normal-mode action. New action-context helpers:
`stage_paths`, `unstage_paths`, `discard_paths`, `apply_hunks`.
Combined hunk patches emit each file header once with that file's hunks in
pre-image order, matching what `git diff` produced.

## Evidence

- Test-first: `tests/visual.lua` failed first (no `x` mapping registered);
  the inline-hunk regression fails against the old `item.stage` mapping
  (checked by temporarily reverting it).
- Automated (`scripts/test`): visual s/u/-/X on status files including a
  glob-character filename, a deleted file, skipped-item reporting, a single
  confirmation listing every file, and staged content surviving discard;
  visual s/u across hunks in two files on the diff surface; a stale hunk
  making the whole batch fail with the index unchanged; inline-diff hunk
  staging in status (normal and visual); mixed selections refused; a
  no-trailing-newline hunk combined with another file staying byte-exact.
  All index assertions use `git diff --cached --name-only -z`.
- Adversarial, against real Git 2.50.1 in disposable repos: `git add`,
  `git restore --worktree` and `git restore --staged` with one non-matching
  `:(literal)` pathspec all fail the whole call and change nothing. Repeated
  per-hunk headers for one file also applied correctly (even with duplicate
  zero-context lines), but are not relied on.
- Unverified: very large selections are bounded by the OS argv limit (no
  `--pathspec-from-file` yet). Manual feel in a real session.

## Drift check

Visual `-` is two Git calls (unstage, then stage), so it is not atomic
across the two groups; a failure in the second leaves the first applied
and is reported. Selections spanning file rows and hunks are refused; a
smarter rule (e.g. file row wins over its own hunks) is a separate
decision. Visual mode is not added to log, blame, or commit surfaces.
