# Iteration: activity ledger redesign

## Outcome

`:GitActivity` now reads as a ledger instead of a dump: one row per command,
newest first, with a ✓/✗ marker, HH:MM:SS start time, right-aligned
duration, argv without `git`, and `exit N` only on failure. The repository
path appears only when it changes between rows. Output lives in a native
fold under each row, closed by default and expanded for failures. NULs from
`-z` commands render as line breaks and other control bytes as `<xx>`.

## Item/action seam

Rendering lives in `lua/currantgit/activity.lua` (pure: ledger in, lines,
fold levels, items, highlights out). Each row is an `activity:<n>` item;
`activity.toggle_output` (`=`, also `<CR>`) is a registered action, so the
discovery line and `g?` footer describe it. The ledger records now carry
`time`, `stdout`, and `stderr` alongside the existing `output`.

## Evidence

- Automated: `scripts/test` asserts no NUL/control bytes in buffer lines,
  one item per ledger entry, newest-first order, failure/success markers,
  `exit N` only on failure, closed folds for success, open folds for
  failure, `=`/`<CR>` toggles, `g?` help, and `r` re-rendering.
- The NUL assertion was written first and failed against the old renderer.
- Unverified: manual visual check of highlights in a real colorscheme.

## Drift check

Activity still observes the executor; it adds no Git calls and stays a
separate, opt-in surface.
