# CurrantGit — Project Bootstrap and PRD

Create a new public repository named `CurrantGit`, with the Neovim plugin package named `currantgit.nvim`.

This document is temporarily stored in the Nvmm repository and will be moved into the new CurrantGit repository. CurrantGit should not be implemented inside Nvmm. It needs its own repository, clean Neovim test configuration, Git fixtures, documentation, and release lifecycle.

Internal codename/tagline:

> Vatican Git — the Holy Git

The Vatican/Pope reference is a Tim Pope/Fugitive homage.

## Product thesis

CurrantGit is a Neovim-native Git interface inspired by Fugitive.

It should preserve Fugitive’s speed, keyboard-driven workflows, object navigation, staging semantics, inline diffs, `Gdiff` behavior, and arbitrary `:Git` command execution while making repository state, multi-key actions, folds, and diff composition easier to understand.

The core interaction should still feel like Fugitive:

- fast keyboard actions
- contextual buffer-local mappings
- native Vim folds
- direct file and hunk operations
- no mandatory dashboard workflow
- no slow full-panel reconstruction after every action

The improvement is discoverability and compositional clarity.

## Initial product promise

CurrantGit should let a user open a repository panel and immediately understand:

- what has changed
- what is staged
- what is unstaged
- what is untracked
- what is conflicted
- what action applies to the current file or hunk
- how to open, collapse, stage, reset, diff, blame, or commit
- how to keep a blame view beside the source file and jump through its history
- how to compose multi-key commands without guessing
- how to run an arbitrary Git command when the UI does not expose it

## Core compatibility requirement: `:Git`

CurrantGit must provide a compatible `:Git` command.

At minimum, support:

```text
:Git
:Git status
:Git diff
:Git diff --cached
:Git commit
:Git log
:Git blame
:Git checkout
:Git switch
:Git fetch
:Git pull
:Git push
:Git rebase
:Git merge
:Git cherry-pick
:Git revert
```

The command should:

- accept arbitrary Git arguments
- preserve Fugitive-style command behavior where practical
- display command output in an appropriate Neovim buffer or pager
- support commands that edit files, such as commits and rebases
- refresh CurrantGit state after repository-changing commands
- provide a bang form where Fugitive semantics require it
- avoid restricting users to only predefined workflows

The `:Git` command is not optional. It is part of the product’s escape hatch and compatibility promise.

## Fugitive compatibility goals

Preserve the important Fugitive behaviors.

### Status/index panel

Support:

- staged files
- unstaged files
- untracked files
- conflicted files
- section counts
- file navigation
- file opening
- file staging
- file unstaging
- hunk staging
- hunk unstaging
- discard/reset actions
- commit workflows

The status buffer is the repository sidebar: a focused, refreshable projection
of repository state rather than a dashboard that owns a second navigation
system.

### Blame companion view

Blame is a first-class Fugitive compatibility surface.

Support:

- `:Git blame` on the current file, range, or explicit path
- a synchronized companion split/sidebar with source-line mapping
- ordinary buffer behavior: motion, search, yank, folds, and text-object
  navigation remain available
- compact attribution columns for commit, author, age, and source location
- progressive commit details and changed-path context on the selected line
- optional inline attribution using virtual text without rewriting source lines
- `<CR>` to open the selected commit and return to the source location
- `o`, `O`, and `p` for split, tab, and preview commit targets
- `-` to reblame at the selected commit
- `~` and counted `P` for ancestor/parent blame navigation
- `A`, `C`, and `D` column resizing
- `g?` contextual help and `gq` close-and-return behavior

Preserve the behavior and navigation semantics, not Fugitive’s implementation
details. CurrantGit should use explicit surface state, stable line mappings,
and modern Neovim APIs instead of temporary-file coupling and legacy Vimscript
helpers.

Blame should be richer without becoming a dashboard. The blame surface is a
read-only projection with buffer-native semantics; the source buffer remains
authoritative. Detailed commit metadata is progressive disclosure, and inline
attribution is optional rather than a prerequisite for the core blame flow.

### Existing key behavior

Preserve the meaning and feel of Fugitive’s important mappings:

```text
s       stage file or hunk
u       unstage file or hunk
-       toggle staged state
U       unstage everything
X       discard the current change
=       toggle inline diff
>       insert inline diff
<       remove inline diff
dd      open horizontal diff
dv      open vertical diff
ds/dh   open diff split
g?      show contextual help
```

The exact Fugitive mapping behavior should be treated as the compatibility target.

## Collapsing and folding

CurrantGit may use a semantic tree internally, but its visible interaction should preserve Fugitive’s native folding feel.

The user should be able to use normal fold operations:

```text
za      toggle current fold
zA      toggle recursively
zM      close all folds
zR      open all folds
zo      open current fold
zc      close current fold
```

The same collapse behavior should work across:

- repository sections
- files
- inline diffs
- diff files
- diff hunks
- unchanged context
- blame sections
- log sections
- rebase plans
- conflict sections

Collapsed rows should remain informative:

```text
▸ Unstaged changes (7 files)

▾ App.swift
  ▸ Hunk 1 · +4 -1
  ▾ Hunk 2 · +2 -8

▸ WindowController.swift · 3 hunks
```

The goal is a semantic tree underneath, presented as a fast Fugitive-style folded buffer.

## Diff model

All diff views should use a shared comparison model.

Support:

```text
working diff   index versus working tree
staged diff    HEAD versus index
revision diff  arbitrary Git revision comparisons
Gdiff         Fugitive-compatible revision comparison behavior
```

Each comparison should be renderable as:

- inline diff
- folded inline diff
- horizontal split
- vertical split
- three-way comparison where appropriate
- arbitrary revision comparison

`=` must continue to mean “toggle the inline diff for the file under the cursor.”

The inline diff should become part of the same collapsible structure as the file:

```text
▾ App.swift
  file entry
  ▾ inline diff
    ▸ Hunk 1
    ▾ Hunk 2
```

`Gdiff` should be another presentation of the shared diff model, not a separate implementation.

## Discovery bar

Add a contextual discovery bar to the existing panel.

Example:

```text
s stage   u unstage   d diff   c commit   ? all actions
```

When the cursor is on a file:

```text
FILE: App.swift
<CR> open   = inline diff   d diff   b blame   s stage   u unstage
```

When composing a multi-key action:

```text
c…
c commit   a amend   f fixup   r reword   Esc cancel
```

The bar should:

- show only actions valid in the current context
- describe the actual active mapping
- expose multi-key compositions
- show dangerous actions clearly
- update as the cursor moves
- update as the fold state changes
- be disableable through configuration

The bar should be generated from structured action metadata rather than maintained as an unrelated cheat sheet.

## UI direction

CurrantGit should be buffer-first but visually polished.

The primary interface should be a real Neovim buffer with:

- normal cursor movement
- native folds
- searchable text
- yankable paths and hashes
- standard Vim navigation
- buffer-local mappings
- optional mouse interaction
- compatibility with existing Neovim workflows

The visual quality should come from:

- strong hierarchy
- restrained spacing
- useful section headers
- deliberate highlight groups
- clear staged/unstaged/conflicted states
- informative fold text
- aligned change counts
- subtle separators
- readable branch and repository metadata
- a contextual discovery bar
- consistent icons and signs

Avoid:

- oversized floating dashboards
- web-style card layouts
- excessive borders
- decorative UI that reduces information density
- replacing normal Neovim movement with custom navigation
- full-buffer redraws that cause flicker

Example target layout:

```text
CurrantGit   main  ↑2 ↓1              3 staged · 5 unstaged
────────────────────────────────────────────────────────────

▾ Staged changes (2 files)

  M  App.swift                         +12  -3
  M  GitModel.swift                     +4  -1

▾ Unstaged changes (5 files)

  ▾ M  WindowController.swift           +28 -11
      ▸ Hunk 1                          +8  -2
      ▾ Hunk 2                          +20 -9

  ?  Notes.md                           untracked

────────────────────────────────────────────────────────────
s stage   u unstage   = inline diff   d diff   c commit   ? help
```

### UI layers

The panel should have four visual layers:

1. Repository header
2. Foldable content
3. Inline diff content
4. Discovery bar

The renderer should turn the semantic tree into a buffer-native surface. Each
rendered node should reference a semantic item and have:

- visible text
- stable node ID
- stable item ID
- item kind and semantic target
- source range
- highlight group
- fold metadata
- available actions
- optional sign or icon
- optional virtual text

Use extmarks, signs, virtual text, and native folds where useful, but keep the primary content represented as ordinary buffer lines.

The renderer must support incremental updates. Staging one hunk should update only the affected file or section and should preserve:

- cursor position
- fold state
- inline-diff state
- scroll position where possible
- discovery-bar context

Define dedicated highlight groups for repository metadata, file states, diff lines, hunk headers, folded nodes, discovery-bar keys, descriptions, and dangerous actions. The default theme should be attractive without requiring another plugin, while allowing users to override every highlight group.

## Internal model

Use a semantic tree internally.

```lua
{
  id = "working:App.swift:hunk:2",
  kind = "section" | "file" | "hunk" | "context" | "change",
  label = "Hunk 2",
  path = "App.swift",
  start_line = 42,
  end_line = 58,
  children = {},
  collapsed = false,
  actions = {},
}
```

Every node should have:

- stable identity
- node type
- visible line range
- parent/child relationships
- fold state
- available actions
- Git target information

Use stable item and node IDs to preserve fold and inline-diff state across
refreshes. Every meaningful surface element—including repository sections,
status entries, additions, deletions, modifications, renames, copies, binary
changes, conflicts, changed lines, people, and remote references—is a domain
item with capabilities; nodes are its placement in a particular rendered
surface. Custom actions should target items, not buffer line numbers. External
providers may enrich items with identities and links, such as opening a commit
author’s GitHub profile, without making that provider part of the core Git
model. Native adapters may similarly bind local-path items to actions such as
opening the default application or revealing a file in Finder, without making
macOS behavior part of the Git model.

## Architecture

CurrantGit should be organized around a small authoritative core with replaceable presentation and transport layers.

```text
                 ┌─────────────────────┐
                 │   Neovim commands   │
                 │ :Git / mappings     │
                 └──────────┬──────────┘
                            │
                 ┌──────────▼──────────┐
                 │   Action registry   │
                 │ stage, diff, commit │
                 └──────────┬──────────┘
                            │
                 ┌──────────▼──────────┐
                 │   CurrantGit core   │
                 │ repo state + tree   │
                 │ folds + snapshots   │
                 └──────┬─────────┬────┘
                        │         │
              ┌─────────▼───┐ ┌───▼──────────┐
              │ Buffer UI   │ │ RPC gateway  │
              │ folds/bar   │ │ optional     │
              └─────────────┘ └──────┬───────┘
                                     │
                              ┌──────▼──────┐
                              │ Nvmm/native │
                              │ clients     │
                              └─────────────┘
```

### Core

The core owns:

- repository snapshots
- Git changes
- files and hunks
- diff specifications
- semantic tree nodes
- stable node identities
- fold state
- action availability
- refresh/reconciliation

The core must not depend on a specific UI.

### Git execution

Git commands should run asynchronously through a dedicated executor.

The executor owns:

- process startup
- argument construction
- stdout/stderr capture
- exit status
- cancellation
- timeouts
- environment handling
- repository-root resolution

`:Git` and all UI actions should use the same executor.

Start with Git’s CLI through Neovim’s async process APIs. Do not begin with libgit2.

### UI projection

The standard Neovim UI renders core snapshots into:

- Fugitive-style status buffers
- folded file and hunk sections
- inline diffs
- diff splits
- discovery bars
- contextual help

A future Nvmm client should consume the same core snapshots and actions rather than reimplementing Git behavior.

### RPC gateway

RPC is optional in the first user-facing release, but the core should expose a clean protocol boundary.

The RPC gateway should support:

- repository snapshot requests
- diff requests
- action requests
- refresh notifications
- action progress
- errors
- cancellation
- capability discovery

Example request:

```json
{
  "id": 42,
  "method": "action.stage_hunk",
  "params": {
    "repository": "/path/to/repo",
    "node_id": "working:App.swift:hunk:2"
  }
}
```

Example response:

```json
{
  "id": 42,
  "result": {
    "ok": true,
    "revision": 19
  }
}
```

Example event:

```json
{
  "event": "repository.updated",
  "revision": 20,
  "snapshot": {
    "repository": "/path/to/repo",
    "head": "main",
    "changes": []
  }
}
```

The protocol should include:

- request IDs
- protocol version
- snapshot revisions
- structured errors
- capability negotiation
- bounded message sizes
- cancellation
- no arbitrary Lua evaluation
- no implicit shell execution through RPC

The first transport may be an in-process Lua adapter. Later transports may use Neovim RPC, MessagePack-RPC, or a private Unix socket for native clients.

Do not build a daemon before the core model and test harness prove that the protocol is useful.

## Performance requirements

CurrantGit should preserve the feeling of Fugitive being immediate.

Requirements:

- update only the affected subtree after staging or resetting
- preserve fold state across refreshes
- preserve inline-diff state by stable file identity
- avoid blocking the UI on Git commands
- use asynchronous Git execution where appropriate
- avoid unnecessary full-buffer rewrites
- keep cursor position stable where possible
- keep the discovery bar responsive
- support repeated refreshes without visual flicker

## Proposed repository structure

```text
currantgit.nvim/
├── lua/currantgit/
│   ├── init.lua
│   ├── git/
│   │   ├── system.lua
│   │   ├── status.lua
│   │   ├── diff.lua
│   │   ├── commit.lua
│   │   └── revisions.lua
│   ├── model/
│   │   ├── repository.lua
│   │   ├── node.lua
│   │   ├── tree.lua
│   │   └── state.lua
│   ├── panel/
│   │   ├── status.lua
│   │   ├── renderer.lua
│   │   └── refresh.lua
│   ├── folds/
│   │   ├── classifier.lua
│   │   ├── state.lua
│   │   └── text.lua
│   ├── actions/
│   │   ├── registry.lua
│   │   ├── staging.lua
│   │   ├── diff.lua
│   │   └── navigation.lua
│   └── discovery/
│       ├── bar.lua
│       ├── help.lua
│       └── trie.lua
├── plugin/
│   └── currantgit.lua
├── doc/
│   └── currantgit.txt
├── tests/
│   ├── fixtures/
│   ├── minimal-init.lua
│   ├── unit/
│   ├── integration/
│   └── functional/
├── scripts/
│   ├── test
│   ├── test-clean
│   └── smoke-nvim
├── docs/
│   ├── PRD.md
│   ├── architecture.md
│   └── decisions/
├── README.md
└── AGENTS.md
```

## Testing strategy

Use multiple validation layers:

```text
pure model tests
  ↓
Git fixture integration tests
  ↓
headless clean-Neovim tests
  ↓
scripted real-Neovim keypress loops
  ↓
manual visual smoke checks
```

The scripted loop must launch Neovim with only `tests/minimal-init.lua`, send actual keys, and inspect:

- visible buffer lines
- fold levels and closed ranges
- cursor position
- staged and unstaged Git state
- diff contents
- discovery-bar text
- refresh behavior
- mapping behavior

Important interactions:

```text
:Git
=
za
zM
zR
s
u
-
>
<
dd
dv
g?
```

Verify that:

- `:Git` executes arbitrary Git commands
- `=` toggles the correct inline diff
- working and staged diffs are distinct
- `za` collapses the current semantic node
- folds survive refreshes
- staging a hunk updates only the affected area
- `Gdiff`-style comparisons work
- multi-key actions are understandable while composing
- invalid prefixes recover cleanly

### Git fixtures

Create temporary repositories covering:

- clean repository
- modified file
- staged file
- staged and unstaged portions of the same file
- untracked file
- deleted file
- renamed file
- merge conflict
- multiple hunks
- binary file
- empty repository
- worktree where relevant

### Manual visual smoke checks

After automated tests pass, manually inspect:

- initial panel layout
- collapsed section appearance
- collapsed hunk appearance
- inline diff appearance
- discovery-bar readability
- cursor movement
- refresh behavior
- staged/unstaged transitions
- diff split transitions
- conflict presentation

Document which checks are automated and which are manual.

## Development sequence

### Phase 1 — Repository and documentation

Create:

```text
README.md
AGENTS.md
docs/PRD.md
docs/architecture.md
tests/minimal-init.lua
```

### Phase 2 — Clean test harness

Prove that the harness can:

- create a temporary repository
- launch clean Neovim
- load CurrantGit
- execute `:Git`
- send keys
- inspect buffers
- inspect folds
- inspect Git state
- repeat reliably

### Phase 3 — Status panel parity

Implement:

- repository discovery
- `:Git`
- staged/unstaged/untracked sections
- file navigation
- staging and unstaging
- native fold behavior
- exact `=` inline-diff behavior
- discovery bar

### Phase 4 — Diff parity and extension

Implement:

- working-tree diffs
- staged diffs
- inline diff folding
- hunk folding
- `dd`, `dv`, and related diff splits
- `Gdiff`-style comparisons
- stable fold state

### Phase 5 — Broader Git surfaces

Extend the same semantic, fold, and action system to:

- logs
- blame
- branches
- worktrees
- conflicts
- rebase plans
- commit editing

## Documentation requirements

Documentation is part of the product.

Maintain:

- product thesis
- user-facing README
- architecture explanation
- keymap reference
- `:Git` command reference
- compatibility notes
- test methodology
- decision records for major architectural choices
- explicit validation boundaries

Do not document unimplemented behavior as complete.

Every feature should state:

- what it does
- which Fugitive behavior it preserves
- which new behavior it adds
- how it is tested
- what remains unverified

## First implementation task

After creating the repository:

1. Write `docs/PRD.md` using this specification.
2. Write `docs/architecture.md`.
3. Create `tests/minimal-init.lua`.
4. Create the first Git fixture.
5. Implement the clean-Neovim smoke harness.
6. Prove the harness can launch Neovim, load CurrantGit, and execute `:Git`.
7. Implement the first status-panel slice.
8. Add the `=` inline-diff behavior.
9. Add native folding and the discovery bar.
10. Run the real Neovim test loop repeatedly.

Do not begin by porting every Fugitive implementation detail.

Port Fugitive’s behavior where parity matters, especially:

- `:Git`
- folding
- inline diffs
- staging
- revision navigation
- `Gdiff`

The first success criterion is:

> Open a clean repository, run `:Git`, press `=`, collapse a hunk with `za`, stage it with `s`, refresh the panel, and still feel like Fugitive—only clearer.
