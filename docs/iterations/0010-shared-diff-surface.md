# Iteration: shared diff surface

## Outcome

The status `d` action now opens a dedicated read-only diff surface. Unified
diff hunk headers become semantic fold roots, while the surface remains a
normal Neovim buffer with navigation history.

## Item/action seam

The diff parser is independent of the status renderer. It accepts Git's diff
text and returns lines plus hunk fold metadata; later working, staged, and
revision comparisons can use the same seam.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` opens the mapped diff action, asserts diff content
  and hunk fold levels, and verifies the status surface remains reusable.
- Unverified: staged/revision comparisons and split presentations are later
  slices.

## Drift check

Diff output no longer falls through to the generic command surface. The parser
does not own Git execution, and the UI does not duplicate comparison logic.
