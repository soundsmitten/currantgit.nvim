# Iteration: semantic diff hunk nodes

## Outcome

Parsed diff surfaces now expose stable hunk domain items with old/new ranges,
line mappings, and fold capabilities. Hunk rows remain ordinary native folds
while gaining an identity for future mutations.

## Item/action seam

The diff parser returns rendered lines, fold levels, line-to-item mappings, and
hunk nodes together. Future stage/unstage actions can target the hunk item and
its patch range rather than a cursor line.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` asserts a real diff hunk is a fold root and a
  semantic hunk item.
- Unverified: applying hunk patches is the next slice.

## Drift check

Hunks are domain objects now, but the parser still does not execute mutations.
The renderer and Git executor remain separate seams.
