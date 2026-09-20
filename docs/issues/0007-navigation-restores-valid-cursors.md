# Issue 0007: Restore only valid cursor positions from view history

## Status

Implemented — automated regression green; manual reproduction rerun pending.

## Observed failure

The human reproduced this sequence in the disposable playground:

1. stage `README.md`;
2. open `:Git diff --cached -- README.md`;
3. put the cursor on its only hunk and press `u`;
4. the staged diff refreshes to an empty projection;
5. press `Ctrl-O`.

Neovim raises:

```text
E5108: Lua: .../lua/currantgit/navigation.lua:30:
Invalid cursor line: out of range
```

The hunk action itself succeeded. Independent Git inspection showed an empty
index and the README edit intact in the worktree. The failure is confined to
view-history restoration after the projection shrinks.

## Cause to verify

`navigation.restore()` restores the saved cursor with
`nvim_win_set_cursor(window, entry.cursor)` without reconciling it against the
current line count of `entry.buffer`. CurrantGit reuses named status, diff, and
log buffers; after a refresh, a historical entry can therefore refer to the
same valid buffer ID but to a line that no longer exists. `winrestview()` also
receives the stale saved view.

Verify this explanation with the regression test rather than treating it as
settled merely because it matches the stack trace.

## Required behavior

- Back and forward navigation must never throw because a reused buffer became
  shorter or empty.
- Restore the saved semantic target when it still exists. Where this slice has
  no stable semantic target, clamp the cursor and view to a valid, predictable
  position in the current projection.
- Clamp both line and byte column safely; a surviving line may also be shorter
  than the saved line.
- Reconcile `lnum`, `topline`, and related saved view fields before or after
  `winrestview()` so the restored view cannot remain invalid.
- Preserve the existing boundary: when CurrantGit local history is exhausted,
  `Ctrl-O` and forward navigation fall through to normal Neovim jump history.
- Do not change Git state, hunk semantics, or buffer-reuse policy as part of
  this focused fix.

## Regression coverage

Write the failing mapped interaction first. Reproduce the exact
status-to-staged-diff-to-empty-diff sequence and press the actual `Ctrl-O`
mapping. Assert no Lua error, a valid cursor, and the intended restored
surface. Then cover:

- back and forward after a status refresh removes rows;
- back and forward after a log refresh returns fewer commits;
- a saved column beyond the end of a surviving shorter line;
- a one-line or empty projection;
- an invalid/deleted buffer entry;
- normal Neovim jump fallback when local history is exhausted.

Update the relevant iteration evidence and `docs/gotchas.md` with the reusable
Neovim rule: a valid reused buffer does not imply that a saved cursor/view is
still valid for its new contents. Manual validation should repeat the original
sequence after the automated regression is green.
