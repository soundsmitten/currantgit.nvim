# Iteration: semantic status sections

## Outcome

The status projection now groups changes into stable semantic sections for
staged changes, unstaged changes, untracked files, and conflicts. Section rows
are fold roots; file rows remain domain items with their existing actions.

## Item/action seam

Section nodes carry stable IDs and a `collapse` capability. File items remain
the source of open, diff, and future staging actions. Rendered rows only
project those nodes into the buffer.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` asserts section discovery, fold levels, native
  collapse/open behavior, and existing mapped interactions.
- Unverified: preserving fold state across refreshes is a later slice.

## Drift check

The implementation uses Neovim's native fold commands and keeps the semantic
section/item mapping in buffer-local state. It does not introduce a second
collapse vocabulary or make line numbers the public identity of an item.
