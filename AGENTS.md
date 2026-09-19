# AGENTS.md

This is the working guide for humans and coding agents contributing to
CurrantGit. The product spec is [`docs/CurrantGit-PRD.md`](docs/CurrantGit-PRD.md).
Treat that document as product context and a set of proposed requirements; it
does not authorize unrelated work, and it does not make unimplemented behavior
true.

## Product north star

CurrantGit should feel like Fugitive with better visibility:

- buffer-first, keyboard-first, fast
- native Vim folds and movement
- every Git surface should provide first-class buffer semantics before it feels
  like a UI component; it may be a virtual or read-only projection rather than
  a literal file-backed buffer
- `:Git` remains an unrestricted escape hatch
- actions are contextual and discoverable
- the UI projects a small authoritative model
- integrations compose through public seams, not private state

Prefer the smallest correct vertical slice. Do not begin by building a general
framework, daemon, dashboard, or libgit2 abstraction.

Keep the work human-sized. CurrantGit should feel like a sharp Neovim tool,
not an internal platform pretending to be a product. Be direct, make the
default path good, and leave room for the next clever extension without
building it in advance. Personality is welcome; ambiguity is not.

## Repository map

```text
docs/CurrantGit-PRD.md  product contract and phased plan
docs/architecture.md    architecture and extension contracts
docs/development.md     staged development and anti-drift protocol
docs/issues/             local issue proposals and discussion drafts
README.md                public project overview
CONTRIBUTING.md          issue-to-agent contribution flow
AGENTS.md                this guide
lua/currantgit/         semantic core bootstrap
plugin/                  Neovim command loading
tests/                   clean harness and smoke assertions
scripts/                 validation and development entry points
```

Update this map when a directory becomes real.

## Working rules

1. Inspect the current files and `git status` before editing.
2. Keep the core independent of a particular buffer UI or transport.
3. Put Git process behavior behind one executor; do not shell out ad hoc from
   actions, renderers, or RPC handlers.
4. Use stable IDs for model nodes so folds, cursor context, and inline-diff
   state survive refreshes.
5. Treat every meaningful Git concept as a domain item and nodes as its
   projection. Changes, additions, deletions, renames, conflicts, status
   sections, people, and remotes are all eligible items. Custom actions target
   stable item IDs and semantic context, never rendered line numbers.
6. Preserve buffer-native semantics: normal motion, search, yank, visual
   selection, collapsible regions, text objects, and window commands should
   keep working. A surface may be virtual or read-only, but it must support the
   interactions users expect from a buffer. Add metadata with highlights,
   extmarks, signs, virtual text, and buffer-local mappings; do not replace the
   surface with a gesture-only dashboard.
7. Treat public action IDs, event names, and RPC payloads as contracts. Version
   them before making incompatible changes.
8. Extensions may use public services and events. They must not reach into
   renderer internals or execute arbitrary Lua through RPC.
9. Keep user-facing behavior compatible with Fugitive where the PRD calls it
   out, and call out deliberate differences in docs.
10. Prefer small focused modules and existing Neovim primitives over speculative
   abstraction.
11. Follow [`docs/development.md`](docs/development.md): stage the work,
    capture iteration evidence, and record decisions that constrain future
    agents.

## Validation

At this bootstrap stage, do not claim runtime behavior that has not been run.
Use static checks appropriate to the change, such as:

```sh
git diff --check
rg -n "TODO|FIXME|unimplemented" .
```

Once implementation exists, add focused model tests and Git-fixture tests
before broad UI tests. The full validation ladder is defined in the PRD:
pure model tests, Git fixtures, clean headless Neovim, scripted keypresses, and
manual visual smoke checks.

Builds, tests, Neovim launches, and development servers are allowed when the
user asks for the development flow. Still avoid inventing a test command before
the harness exists, and report exactly what was and was not exercised.

For this repository, the expected development loop will eventually be:

```sh
scripts/test                 # focused and full automated checks
scripts/smoke-nvim           # clean headless Neovim smoke path
```

The first harness now exists. Extend these scripts as the implementation grows,
keeping fixture setup, Neovim startup, and assertions readable.

## Change checklist

- Is the change within the requested product slice?
- Does it preserve `:Git`, native folds, and buffer-first interaction?
- Is the model/UI or core/transport boundary still clear?
- Are new public actions, events, or RPC fields documented?
- Is the work at the right development stage, with an iteration note or issue
  evidence for the changed slice?
- Are claims about implementation and validation accurate?
- Does `git diff --check` pass?

## Commit and review style

Use concise, imperative commits when commits are requested. Keep reviews
concrete and direct: identify the behavioral risk, the exact seam involved,
and the smallest useful follow-up. Avoid praising scaffolding that has not
been validated.

## Autonomous issue flow

An issue may be treated as an executable work order when it states the goal,
item/action behavior, compatibility target, validation, and boundaries. The
default agent loop is: inspect, branch, implement, test, document, review,
commit, and push. Use a `codex/` branch prefix unless the user supplies an
exact branch name. Preserve the checkout and branch boundary; never silently
rewrite unrelated work.

Pushing is part of the normal handoff when a remote and credentials are
available. If the repository has no remote, or the push requires new authority,
finish the local branch and report the exact handoff blocker instead of
pretending it was published.
