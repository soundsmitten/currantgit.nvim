# Iteration: structured action discovery

## Outcome

Action metadata now has two public projections: structured discovery entries
and a WhichKey-compatible mapping table. The status bar, help surface, and
integrations can consume the same contextual registry without scraping buffer
lines.

## Item/action seam

`require('currantgit').discovery()` returns action IDs, keys, labels, and
descriptions for the current item. `which_key()` wraps those same actions with
dispatch callbacks. Keys remain presentation; stable action IDs remain the
integration seam.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` asserts both projections for a real status item.
- Unverified: external WhichKey registration UX is intentionally left to the
  consuming configuration.

## Drift check

The public projections are generated from the action registry. No second
WhichKey map or discovery-only action list was introduced.
