# Iteration: two-pane diff split

## Outcome

`D` on a staged or unstaged change row opens a new tab, old | new, in
native diff mode with the conflict resolver's look (hatched filler,
per-side tints, winbars). Staged compares `HEAD:<path>` with `:0:<path>`;
unstaged compares `:0:<path>` with the real, editable worktree file. Added
and deleted files get an empty labelled side. No Git mutation was added.

## Item/action seam

- `lua/currantgit/panes.lua` now holds what both views share: the palette
  and blend, side tint groups, `winhighlight` builder, read-only
  `currantgit://<kind>/<side>/<path>` buffers, hatched filler, `diffthis`
  for the tab. `conflict.lua` uses it with no behavior change (its tests
  are unchanged).
- `lua/currantgit/diffsplit.lua` owns the `item.diff_split` action and
  layout, running Git only through the injected executor.
- `init.lua` changes are hooks only: require, setup/register, and the `D`
  status mapping. The row's section comes from the existing
  `current_item_section`.
- Key: `D`, not Fugitive's `dv`: `d` is already a single-key mapping here,
  so `dv` would make `d` wait for 'timeoutlen'.

- `gq` closes either view's tab from any pane (`panes.map_quit`); the
  mapping is dropped on `BufWinLeave` so the real worktree file doesn't
  keep it.

- `gq` is now universal: every `set_buffer` surface and the deleted-file
  view get it (`quit_surface` in `init.lua`), alongside blame's existing
  one. Per user direction, this widened the init.lua touch beyond hooks.
  `tests/quit.lua` presses it on each surface and in a `:vertical` split.

## Evidence

- `tests/diffsplit.lua` (wired into `tests/smoke.lua`), written first and
  seen failing on discovery: a real repository with unstaged and staged
  edits of `-2:ü [x].txt`, a staged add, a staged delete, and a worktree
  delete, each opened through the real `D` mapping. Asserts pane contents
  against `git show`, read-only/editable sides, winbar labels, diff mode,
  hatched filler, tints, and that `ls-files -s`, porcelain status,
  `git diff` and HEAD are unchanged.
- `scripts/test` passes.

## Not done

- No visual smoke check in a real colorscheme.
- Untracked rows (`/dev/null` vs file) are not offered.
