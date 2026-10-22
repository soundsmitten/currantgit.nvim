# Iteration: read-only conflict resolver (issue 0010, slice 1)

## Outcome

Conflict rows in status are `conflict-file:<path>` items showing
`resolved/total` (or `deleted by us`/`deleted by them`/`deleted by both`/
`binary`). `<CR>` on one opens a new tab: ours | result | theirs in native
diff mode, with the real worktree file in the middle and read-only stage
buffers on the sides. `gb` toggles a read-only base view; `]x`/`[x` jump
between conflict rows in status and between regions in the result pane.
No Git mutation was added.

## Item/action seam

- New module `lua/currantgit/conflict.lua` owns parsing, matching, the
  layout, and the `conflict.open`, `conflict.next`, `conflict.prev`, and
  `conflict.base_toggle` actions. It runs Git only through the executor
  `init.lua` injects.
- Region items `conflict:<path>:<n>` number from the re-merged stages, so a
  region resolved earlier in the file never renumbers a later one.
- `init.lua` changes are hooks only: the item kind/id, the row annotation,
  annotating before render, `<CR>` resolved per item kind, and `]x`/`[x`.
  `item.stage`/`item.toggle`/`item.diff`/`item.blame` also apply to
  conflict rows; discard and unstage no longer do (restore is slice 3).

## Evidence

- Test-first: `tests/conflict.lua` failed (no `currantgit.conflict` module)
  before the implementation existed.
- Automated, all against real `git merge` fixtures: `merge`/`diff3`/`zdiff3`
  counts (1/2/2 for the same edit), resolving a region in the worktree,
  add/add (no stage 1), delete/modify both ways, binary, and a
  `-2:ü [x].txt` path through the real mappings (`<CR>`, `]x`, `[x`, `gb`).
  Every block asserts `git ls-files -s`/`-u`, status, HEAD and MERGE_HEAD
  are unchanged.
- Not exercised: rebase and cherry-pick conflicts (same index stages, not
  separately fixtured), custom `conflict-marker-size`, and visual feel.

## Drift check

Read-only throughout. The adversarial validation pass from
`docs/development.md` applies to slice 3 (mark resolved/restore/continue),
which is where the index changes.
