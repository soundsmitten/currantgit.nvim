# Iteration: valid navigation restoration

## Outcome

Back and forward navigation no longer throws when a reused CurrantGit surface
became shorter after it was recorded. Restoration clamps stale line, byte
column, and window-view coordinates to the buffer's current contents and skips
history entries whose buffers were deleted.

## Item/action seam

The change stays inside the existing window-local navigation history. It does
not alter semantic items, buffer reuse, Git actions, or the mapped navigation
contract.

## Evidence

- Test-first: the mapped `<C-O>` regression failed against the unfixed code at
  `nvim_win_set_cursor()` with `Invalid cursor line: out of range`.
- Automated: `scripts/smoke-nvim` covers a shortened projection, a stale byte
  column, a stale saved view, an empty projection, deleted history buffers,
  and mapped back/forward restoration. The full clean headless smoke and safety
  paths pass.
- Manual: the original staged-diff reproduction remains to be rerun by a human.

## Drift check

Normal Neovim jump fallback remains unchanged when CurrantGit's local history
has no valid destination. The fix adds no Git execution or mutation behavior.
