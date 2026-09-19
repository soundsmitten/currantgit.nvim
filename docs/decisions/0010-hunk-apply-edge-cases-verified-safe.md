# 0010: `git apply` edge cases for hunk stage/unstage verified safe as-is

## Context

The audit continuation's item 3 flagged four untested `git apply --cached`
edge cases for `stage_hunk`/`unstage_hunk`: no-trailing-newline files,
sequential multi-hunk staging, apply-failure atomicity, and a "stale hunk"
whose underlying file changed after the diff was rendered. Each was built as
a real, disposable-repository fixture and driven through the actual
CurrantGit UI (mapped `s`/`u` keys), not just raw `git apply`.

- **No trailing newline:** Git represents this with a literal
  `\ No newline at end of file` marker line, which `diff.lua`'s patch
  reconstruction already passes through untouched (it just captures raw diff
  output lines verbatim). Staging produced a byte-exact match with the
  working tree content, including the absence of a trailing newline.
- **Sequential multi-hunk staging:** `stage_hunk`'s callback always re-runs
  `open_diff_args` (a fresh `git diff`) after a successful apply, so a second
  hunk's patch is regenerated against the now-current index rather than
  reused stale. Staging two hunks in the same file, one at a time, correctly
  staged both with nothing left unstaged.
- **Apply-failure atomicity:** confirmed directly against `git help apply`
  ("For atomicity, git apply by default fails the whole patch and does not
  touch the working tree when some of the hunks do not apply") and
  reproduced empirically for `--cached`: re-applying an already-applied
  hunk's patch a second time fails outright and leaves the index
  byte-for-byte unchanged. CurrantGit never passes `--reject`, so this
  guarantee applies to `stage_hunk`/`unstage_hunk` as written.
- **Stale hunk:** `git apply --cached` is defined purely in terms of the
  index, never the working tree. If the worktree changes again after a diff
  is opened but before the index is touched, staging the (visually stale)
  hunk still succeeds — it stages exactly the patch captured at render time,
  and the worktree's later, unrelated edit is left completely untouched.
  This is correct Git behavior, not data loss, but it is a real, non-obvious
  surprise a user could hit (the diff buffer looks stale, but staging it
  "succeeds" using old content).

## Decision

No code change was made for any of the four sub-cases: each was either
already correct (no-trailing-newline, sequential staging, atomicity) or is
expected, non-destructive Git behavior that CurrantGit has no way to detect
without inventing a staleness-tracking mechanism Git itself doesn't provide
(the "pinned to render time" case). Recorded as a decision rather than left
implicit, so a later agent doesn't spend time "fixing" behavior that is
already correct, and so the render-time-pinning behavior is treated as a
known, accepted characteristic rather than rediscovered as a surprise.

Regression coverage: `tests/safety.lua`, `test_hunk_stage_no_trailing_newline`,
`test_hunk_stage_sequential_multi_hunk`, `test_hunk_stage_atomic_on_conflict`,
`test_hunk_stage_pinned_to_render_time_not_worktree`.

## Consequences

- CurrantGit can now claim, with runtime evidence, that hunk stage/unstage
  correctly handles missing trailing newlines, sequential multi-hunk
  staging, and fails atomically (no partial index corruption) when a patch's
  context no longer matches.
- CurrantGit cannot claim a diff buffer always reflects "what staging this
  hunk will do to the current worktree" — only "what staging this hunk will
  do to the current index," which is what `git apply --cached` actually
  guarantees. A future UX improvement could refresh the diff buffer more
  aggressively (e.g. on `FocusGained` or a file-change watcher) to narrow
  this window, but that is a discoverability improvement, not a
  correctness fix — nothing here corrupts state or silently discards data.

## Revisit if

A future change adds any kind of buffer staleness detection or
auto-refresh-on-external-change — re-verify this record's claims still hold
under that new behavior rather than assuming it does.
