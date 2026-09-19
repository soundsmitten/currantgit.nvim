# Iteration: blame commit view

## Outcome

Blame attribution rows now expose `<CR>` to open a read-only commit view. The
commit projection uses Git's patch/stat output and participates in the same
local view history, so Ctrl-O returns to blame before `gq` returns to source.

## Item/action seam

The selected blame row supplies a stable commit identity. Commit rendering is
another projection of that identity; it does not make the rendered attribution
line the target.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` opens a blame commit, checks commit content,
  returns through Ctrl-O, and closes the companion split.
- Unverified: reblame and parent navigation remain later slices.

## Drift check

Commit navigation extends the existing blame/source history instead of
creating a second navigation stack or replacing the source buffer.
