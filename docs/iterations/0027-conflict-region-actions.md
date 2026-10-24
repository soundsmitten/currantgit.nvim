# Iteration: conflict region actions and single-pane layout (issue 0010, slice 2)

## Outcome

Inside a conflict region in the resolver's result pane, `co`/`ct`/`cb`/`cB`/
`c0` take ours, theirs, both (either order) or base. Each choice replaces
the region, markers included, as one undo step, labels it "✓ <choice>" and
updates the "n of m resolved" winbar. The region under the cursor gets the
stronger tints. `gl` switches between ours | result | theirs and the result
alone; `conflict.layout = "single"` makes the single pane the default.

Still no Git mutation: nothing writes the index, and the file is only saved
by the user's own `:w`.

## Item/action seam

- New actions on `conflict` region items: `conflict.take_ours`,
  `conflict.take_theirs`, `conflict.take_both`,
  `conflict.take_both_theirs_first`, `conflict.take_base`; plus
  `conflict.layout_toggle`. Region `state` now reports the choice
  (`ours`/`theirs`/`both_ours_first`/`both_theirs_first`/`base`), `edited`
  for a hand-edited region, and goes back to `unresolved` on undo.
- Keys deviate from the issue's `o`/`t`/`b`/`0`: see docs/decisions/0014.
- Choices remember their position with extmarks, so they follow later edits.
- `init.lua` only passes the configured layout to the conflict module.

## Evidence

- Test-first: `test_region_actions` and `test_take_base_without_base` failed
  first (no current-region tint, then no `co` mapping).
- Automated: each key's inserted lines, one-step undo, state and label;
  native `cb` outside a region; `c0` refusing on merge-style markers; the
  layout toggle both ways (diff mode off and back on); the `single` default;
  the file on disk and the index unchanged throughout.
- Not exercised: feel and colors on screen, rebase/cherry-pick conflicts.

## Drift check

Buffer edits only. Slice 3 (mark resolved, restore, continue/skip/abort)
is where the index changes and the adversarial pass applies.
