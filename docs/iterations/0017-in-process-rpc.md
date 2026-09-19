# Iteration: in-process RPC seam

## Outcome

CurrantGit now exposes a small in-process RPC adapter with protocol versioning,
capability discovery, request IDs, structured errors, revisioned results, and
event subscribers.

## Item/action seam

Handlers are explicitly registered by method name. The adapter does not
evaluate arbitrary Lua, shell text, or implicit commands. Future repository
and action handlers can use the same request/response contract.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` checks capabilities, a handler response, revision
  increments, and unknown-method errors.
- Unverified: an external MessagePack-RPC or native transport remains future
  work until the core snapshot/action handlers are mature.

## Drift check

This is a protocol boundary, not a daemon. No background process, socket, or
second Git implementation was introduced.
