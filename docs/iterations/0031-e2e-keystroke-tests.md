# Iteration: end-to-end tests driven by real keystrokes

## Outcome

`scripts/e2e` runs `tests/e2e/scenarios.lua` with `nvim -l`. Each scenario
builds its own fixture repository and starts its own
`nvim --embed --headless` child with isolated XDG directories and an empty
global Git config. The driver types keys with `nvim_input` and checks Git
state with its own `git` calls. RPC reads of the child (current line, mode,
`b:` variables) are observation only. `scripts/test` now runs it after the
smoke suite.

Scenarios cover status stage/unstage, visual multi-stage, discard with Cancel
and confirm, native folds and `=`, hunk stage/unstage from the diff, the `:Git`
escape hatch with a quoted message, blame open/close, log to commit, `g?`
opening `:help`, the read-only resolver, `co` with undo and `:w`, and `cb`
staying native outside a region.

Waits use signals only the action under test can satisfy (docs/gotchas.md):
index or file state from the driver, a changedtick or buffer switch, the
child entering a prompt (`vim.ui.select` shows up as mode `c`, not
`blocking`). "Settled" means normal mode with no child subprocess for 60 ms,
observed from the OS process tree, so the plugin needs no new API for it.

## Evidence

- All 12 scenarios pass on top of the landing merge for #22/#23/#25.
- Each check was shown to fail on broken code: `s` routed to unstage failed
  the stage scenario; discard without its prompt failed the discard
  scenario; a resolver that writes the file on open failed the read-only
  scenario.
- Two first-draft expectations were wrong and were fixed to match real
  behavior, not the other way round: `gq` from blame returns to the source
  file, and `$cb` leaves the cursor's character (`nvim --clean` gives the
  same result).
- Not run: repeated runs to measure flakiness, other Neovim versions
  (only 0.12.4), Linux.
