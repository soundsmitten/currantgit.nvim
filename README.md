# CurrantGit

Git, but still a Neovim buffer.

CurrantGit is a Neovim-native Git interface inspired by Fugitive. It keeps the
fast, keyboard-first workflow—`:Git`, folds, staging, inline diffs, and
revision navigation—while making state and available actions easier to see.

It is opinionated on purpose: small surfaces, strong seams, useful defaults,
and no ceremony between “I saw the change” and “I fixed the change.” The
interface should feel composed, not ceremonial.

CurrantGit is also an experiment in how far a coherent agent-assisted
development loop can go when the human supplies direction, taste, and
boundaries while the agent carries the investigation, implementation,
validation, and documentation. The experiment is deliberately serious: the
work is allowed to move quickly, but every claim still has to earn its way
through the repository, the harness, and the review trail.

> Vatican Git — the Holy Git

## Status

This repository is in the design and bootstrap phase. The first executable
slice now exists: a clean-Neovim harness, a temporary Git fixture, and a
minimal `:Git` status surface with semantic change items. The broader product
contract is in [`docs/CurrantGit-PRD.md`](docs/CurrantGit-PRD.md); the docs
continue to distinguish direction from completed behavior.

## Product shape

- A real buffer is the primary UI.
- A repository sidebar makes status, diffs, and actions glanceable without
  becoming a dashboard.
- Blame is a source-linked, buffer-first companion view with rich attribution,
  commit navigation, and reblame.
- Native Vim movement and folds remain the source of truth for interaction.
- `:Git` is the escape hatch: arbitrary Git arguments must stay possible.
- A small semantic core owns repository state, diffs, nodes, and actions.
- Every meaningful Git concept is a domain item with identity and capabilities;
  optional providers can enrich people, commits, and remotes.
- Native adapters can add actions such as opening a file or revealing it in
  Finder without coupling the Git core to macOS.
- Presentation, transport, and integrations are replaceable at the edges.
- Refreshes should reconcile the affected subtree instead of rebuilding the
  world.

The target experience is familiar to Fugitive users: open a repository, see
what changed, press a key, and keep moving. The discovery bar adds clarity
without turning the workflow into a dashboard. The interesting parts stay
close to the user: the item under the cursor, the action it supports, and the
next useful view.

## Configuration

The default setup is intentionally enough to get moving:

```lua
require("currantgit").setup()
```

When you want to tune the surface, options stay small and discoverable:

```lua
require("currantgit").setup({
  git = { command = "git" },
  ui = {
    title = "My Git",
    show_clean = true,
    show_branch = true,
    show_counts = true,
    icons = {
      modified = "M",
      added = "+",
      deleted = "-",
      renamed = "→",
      untracked = "?",
    },
  },
})
```

Configuration is deeply merged over opinionated defaults and validated during
setup. By default, the status header uses the repository name; a title is an
opt-in prefix. Options describe product behavior, not renderer internals.

## Architecture

The core is deliberately boring. Git runs through one asynchronous executor;
the model produces snapshots and action metadata; the standard Neovim buffer
projects those snapshots for people.

RPC is an extension boundary, not the product itself. An in-process adapter is
the first transport. A future native client, plugin host, or private socket can
consume the same versioned snapshots and request the same named actions without
embedding Lua or reimplementing Git semantics.

See [`docs/architecture.md`](docs/architecture.md) for the contracts and
plugin model.

## Documentation

- [`docs/CurrantGit-PRD.md`](docs/CurrantGit-PRD.md) — product promise,
  compatibility targets, and development sequence
- [`docs/architecture.md`](docs/architecture.md) — core, adapters, RPC, and
  pluggability
- [`AGENTS.md`](AGENTS.md) — contributor and coding-agent guide
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — issue-to-agent workflow and handoff
- [`docs/development.md`](docs/development.md) — stages, iterations, and
  anti-drift guardrails

## Contributing

Read [`AGENTS.md`](AGENTS.md) before changing the repository. Keep changes
focused, preserve the public contracts, and document new behavior alongside
its implementation. Until the first harness exists, validation is limited to
static inspection and the available Neovim smoke checks.
