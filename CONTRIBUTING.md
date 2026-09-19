# Contributing to CurrantGit

Open an issue first.

CurrantGit is designed to be easy to explore through an issue and an agent. An
issue is a conversation starter, not authorization, an executable work order,
or a commitment to build.
Development stages, iteration notes, and anti-drift rules are defined in
[`docs/development.md`](docs/development.md).

The best contribution is usually a focused slice that makes the next slice
obvious. Keep the tool fast, native, and a little opinionated. If a proposal
cannot explain the item under the cursor and the action it enables, it probably
needs a smaller seam.

## The human on the other side

Assume the contributor is experienced, busy, and already carrying enough
context. CurrantGit should reward strong instincts with good defaults, keep
ceremony low, and make the useful path obvious. Contributors should be able to
describe the behavior and intent without first becoming experts in every Lua
or Neovim edge case. Agents are expected to absorb that implementation detail,
choose the correct boundary, and return a clear explanation of the result.

That does not mean hiding Lua from the implementation. The code should be
idiomatic Lua and idiomatic Neovim: small modules, plain tables, local helpers,
explicit state, `setup(opts)`, and familiar API conventions. The agent handles
the translation; the repository keeps the language’s strengths and sensibilities
visible rather than wrapping them in an unnecessary abstraction.

The standard is not maximum configurability. It is tooling that feels calm,
opinionated, and considerate when someone is tired and still needs to get the
work done.

## Project posture

This repository is an all-in experiment in agent-assisted software
development. The human provides intent, product judgment, and the boundaries
that matter; the agent is expected to carry the surrounding work—exploration,
implementation, tests, documentation, and review preparation. That division is
intentional and practical, not theatrical.

The standard remains ordinary engineering quality. Speed is useful when it
creates a tested, legible change. It is not a substitute for evidence, and the
agent is not the subject of the project. The tool is.

## Proposal-first, agent-ready flow

1. Open an issue as a concise proposal: what might be valuable, why now, and
   what question needs answering.
2. Wait for approval, veto, or reshaping before proceeding.
3. Once approved, turn the accepted direction into an execution brief with
   item/action behavior, compatibility target, validation, and boundaries.
4. Read [`AGENTS.md`](AGENTS.md), the PRD, and the relevant architecture notes.
5. Inspect the current checkout and Git state.
6. Create an isolated branch, normally `codex/<short-description>`.
7. Implement the smallest complete vertical slice.
8. Add or update tests, fixtures, and documentation with the behavior.
9. Run the requested development flow, including builds, tests, and Neovim
   launches when authorized.
10. Review the diff, report validation honestly, and commit with a concise
   imperative message.
11. Push the branch and open or update the review handoff when remote access and
   credentials are available.

Once approved, the agent should carry the accepted work through without
requiring a human to translate every implementation step. It should pause only
for missing authority, destructive ambiguity, a product decision that
materially changes scope, or a failed check that needs user input.

## What every change includes

- the user-visible behavior and item/action contract
- focused tests and Git fixtures where applicable
- updated help or architecture docs for public behavior
- a clear distinction between automated, manual, and unverified checks
- an iteration note or equivalent issue evidence for meaningful slices
- a reviewable branch and commit history

Do not claim a feature is complete because its design is documented. Do not
hide runtime gaps behind static checks.

## Review handoff

Agent tooling should capture branches, commits, changed files, checks, push
status, and routine handoff details automatically. Human review should focus on
the behavior, the product decision, and anything that remains genuinely
uncertain—not on filling out a homework sheet. We’re just all too damn tired
around here.
