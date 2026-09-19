# Iteration: command activity

## Outcome

Git execution now records a bounded structured command ledger. `:GitActivity`
projects it into an optional read-only buffer with argv, duration, exit code,
and summarized output; the same records are available to integrations.

## Item/action seam

The ledger is attached to the executor boundary, so status, diff, blame,
actions, and arbitrary Git commands use one event shape. The public
`require('currantgit').command_log()` accessor returns a copy of the records.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` opens the activity surface after real Git calls,
  checks command content, and navigates back to status.
- Unverified: RPC event transport and richer filtering are later slices.

## Drift check

Activity is opt-in and separate from the status buffer. It observes the
executor without making command output the authoritative repository model.
