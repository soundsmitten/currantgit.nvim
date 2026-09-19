# CurrantGit development protocol

CurrantGit grows in small, evidenced stages. Issues begin as proposals, not
instructions. They create room to ask whether an idea is worth pursuing before
any branch, implementation, or validation work is authorized. Once an idea is
approved, the agent and contributor can write the execution brief together.
Design notes are useful only when they clarify the next change.

The project favors strong seams over grand machinery: a small core, a real
buffer-native interaction model, and adapters that earn their place by making
something useful possible. The architecture should remain legible enough that
an experienced contributor can follow an idea from the item under the cursor,
through its capability, to the action and its evidence.

The development loop is intentionally ambitious about delegation and
conservative about claims. An agent may carry a change from exploration through
implementation, testing, documentation, and handoff. The repository still
judges the result by behavior, clarity, and evidence—not by how autonomous the
process sounded.

## Stages

### Stage 0 — Intent

Write the user behavior, affected item kinds, actions, compatibility target,
boundaries, and validation. If the issue cannot say what success looks like,
clarify it before coding.

Exit evidence: an issue or task brief that another agent can execute without
reconstructing the product direction.

### Stage 1 — Semantic seam

Define or reuse the domain items, stable identities, capabilities, and events.
Keep rendered nodes, buffer lines, and window layout out of the core contract.

Exit evidence: item/action examples and a focused model test or fixture plan.

### Stage 2 — Core behavior

Implement the Git operation through the shared executor and action dispatcher.
Handle success, failure, cancellation, stale revisions, and refresh behavior.

Exit evidence: pure tests or Git-fixture tests prove the behavior without a
visual surface.

### Stage 3 — Buffer-native projection

Expose the behavior through a buffer, scratch buffer, or virtual surface that
supports cursor movement, search, yank, mappings, collapse/folds, and window
lifecycle. Preserve stable item identity through refresh.

Exit evidence: clean headless Neovim checks plus a scripted interaction path.

### Stage 4 — Composition

Add provider actions, RPC exposure, or another projection only after the core
behavior works. Keep adapters optional and namespaced. Do not move product
meaning into a provider merely because the provider is convenient.

Exit evidence: capability negotiation, adapter tests, and documentation of the
authority boundary.

### Stage 5 — Handoff

Review the diff for drift, update public docs, record decisions, run the
appropriate validation ladder, commit, and push the branch when authorized and
possible.

Exit evidence: review handoff with changed files, checks, limitations, branch,
commit, and push status.

## Iteration protocol

Each iteration should answer four questions:

1. What user-visible behavior changed?
2. Which item/action seam changed?
3. What evidence was produced?
4. What remains explicitly unverified?

Keep the answer in the issue, pull request, or an iteration note under
`docs/iterations/`. Prefer one small note per meaningful slice over a giant
retroactive changelog.

## Anti-drift guardrails

- One issue, one primary outcome. Split unrelated improvements.
- No new abstraction without a concrete second consumer or a testable seam.
- No UI-only action: actions resolve against item identity and capabilities.
- No provider-owned core truth: Git state remains in the core.
- No line-number APIs: rendered positions are projections, never identity.
- No “implemented” language without runtime evidence at the relevant stage.
- No broad refresh when an affected subtree can be reconciled.
- No compatibility claim without naming the preserved behavior and test.
- No silent scope expansion; record follow-up ideas instead of absorbing them.

When a change feels clever, reduce it to an item, capability, projection, or
adapter. If it does not fit one of those seams, stop and write a decision note
before adding it. Novelty is welcome when it clarifies a user-visible path;
otherwise it is usually just another maintenance bill.

## Validation ladder

Use the cheapest sufficient check and climb only as far as the change requires:

```text
contract and diff checks
  → model tests
  → Git fixtures
  → clean headless Neovim (`scripts/smoke-nvim`)
  → scripted keypresses
  → manual visual smoke
  → release/repository handoff
```

Report each rung separately. Passing static checks does not prove runtime UI
behavior, and passing a focused test does not prove release readiness.

The repository’s first executable loop is `scripts/test`: it validates the
project contract, creates a temporary Git fixture, launches clean Neovim, and
asserts the `:Git` status surface and semantic change items. Extend that loop as
new slices land; do not replace it with an opaque all-in-one command.

The harness must exercise mapped actions, not only the functions beneath them.
Async callback errors are collected and asserted as test failures. A green
command-level test is insufficient if pressing the actual key can still fail.

Configuration follows the same discipline: defaults should be useful, options
should be few, and every documented option should affect observable behavior.
Do not expose an option merely to avoid choosing a default.
