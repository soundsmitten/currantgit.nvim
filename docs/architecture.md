# CurrantGit architecture

CurrantGit has one authoritative Git model and several projections of it. The
Neovim buffer is the first projection; RPC makes other projections possible.
The boundary is intentionally small so a plugin can add useful behavior
without becoming a second Git implementation.

## Shape

```text
commands / mappings / RPC requests
                │
                ▼
        action registry + dispatcher
                │
                ▼
       repository core + snapshots
          │                 │
          ▼                 ▼
   async Git executor   event stream
          │                 │
          └────────┬────────┘
                   ▼
       buffer UI / RPC / future clients
```

The core owns meaning. Adapters own presentation and transport.

## Core contracts

### Snapshot

A snapshot is an immutable, versioned view of one repository:

```lua
{
  repository = "/path/to/repo",
  revision = 19,
  head = { name = "main", oid = "..." },
  sections = { ... },
  capabilities = { "status", "diff", "stage" },
}
```

Nodes have stable IDs, kinds, labels, Git targets, children, and available
actions. Rendering details such as buffer line numbers do not belong in the
snapshot. A refresh reconciles nodes by stable identity so folds and cursor
context can survive.

### Items

Every meaningful thing exposed by CurrantGit is a domain item. It is not merely
a line of text and it is not limited to changed files. Repositories, status
sections, status entries, changes, additions, deletions, modifications, renames,
copies, binary changes, files, hunks, changed lines, commits, blame lines,
people, branches, remotes, conflicts, rebase steps, and plugin-owned objects
can all be items:

```lua
{
  id = "working:App.swift:hunk:2",
  kind = "hunk",
  label = "Hunk 2",
  repository = "/path/to/repo",
  target = { path = "App.swift", start_line = 42, end_line = 58 },
  metadata = { added = 2, removed = 8 },
  capabilities = { "stage", "diff", "open" },
}
```

The item owns identity and semantic data. The node owns placement in a
particular projection: section membership, parent/child structure, fold state,
and visible range. The same commit item can appear in a blame surface, a log
section, and a review extension without becoming three unrelated objects.

The item graph is semantic, not an excuse to wrap every character or UI detail
in an object. A status section is an item because it has identity, children,
state, and actions. A deletion is an item because it has a path, a diff target,
and actions. A separator is not. Renderers project the graph into
buffer-native surfaces; they do not define what exists.

A change item can compose more specific items without flattening them into
display text:

```lua
{
  id = "change:App.swift",
  kind = "change",
  change_kind = "modified", -- added | deleted | renamed | copied | binary | conflict
  path = "App.swift",
  old_path = nil,
  children = {
    { id = "change:App.swift:hunk:2", kind = "hunk" },
  },
  capabilities = { "open", "diff", "stage", "blame" },
}
```

Additions and deletions can expose line items. A rename can expose both old and
new paths. A conflict can expose stages and resolution actions. A binary change
can expose metadata and external diff actions without pretending that binary
content is ordinary text. The renderer chooses how much of this graph to reveal
at once; the model does not lose information to make a panel look simple.

Items should be inspectable and useful to extensions even when no UI is open.
Their IDs are stable within a snapshot lineage, their targets are explicit,
and their metadata is namespaced when supplied by a plugin.

### Actions

Actions are named operations with structured metadata. They are capabilities of
items in context, not a pile of mappings attached to one buffer:

```lua
{
  id = "stage.hunk",
  label = "Stage hunk",
  applies_to = { "hunk" },
  mutates_repository = true,
  is_available = function(ctx, item) ... end,
  run = function(ctx, item) ... end,
}
```

The action registry drives mappings, the discovery bar, help, and RPC. There
must not be one mapping table, one help table, and one RPC switch that drift
apart. A plugin can register an action under its own namespace, such as
`review.open_todo`.

The dispatcher resolves actions in this order:

1. identify the item under the cursor or selection
2. collect actions for its kind and current surface context
3. filter by capabilities, repository state, and user configuration
4. present the action through mappings, discovery, command line, or RPC
5. execute against the item’s stable identity and reconcile the snapshot

That makes custom actions straightforward:

```lua
currantgit.items.register_kind("review.note", {
  actions = { "review.open", "review.resolve" },
})

currantgit.actions.register({
  id = "review.open",
  applies_to = { "review.note" },
  run = function(ctx, item)
    -- use item.id and item.metadata, never rendered line numbers
  end,
})
```

An action may be offered by multiple surfaces, and one item may expose
different actions depending on whether it is viewed in status, blame, log, or a
plugin projection. Keys are presentation choices; item capabilities are the
real API.

### External identity providers

External services enrich items through adapters. The core should not know about
GitHub, GitLab, or a browser. A provider can recognize an item and add
namespaced identities, links, metadata, and actions:

```lua
{
  id = "person:email:maya@example.com",
  kind = "person",
  label = "Maya Chen",
  metadata = {
    email = "maya@example.com",
    github = { login = "mayachen", url = "https://github.com/mayachen" },
  },
  capabilities = { "open", "open_on_github" },
}
```

The optional GitHub adapter could then register:

```lua
{
  id = "github.open_person",
  applies_to = { "person" },
  requires = { "github.url" },
  run = function(ctx, item)
    ctx.open_url(item.metadata.github.url)
  end,
}
```

That same person item could appear in blame, commit details, log entries, or a
future review surface. The integration is composable and removable; GitHub
does not become a dependency of the Git model.

### Native intent providers

The same mechanism can bind local items to native desktop actions. A file,
change, hunk, or repository item with a resolvable local path can expose
capabilities such as:

- `open` — open with the user’s default application
- `reveal` — reveal the path in Finder on macOS
- `copy_path` — copy a normalized path
- `open_terminal` — open a terminal at the containing directory

These are explicit actions, not arbitrary shell escape hatches. A macOS adapter
can implement `reveal` with the native workspace API; another platform can
provide its own implementation or omit the capability. The core only sees the
intent and the item’s validated target:

```lua
currantgit.actions.register({
  id = "native.reveal",
  applies_to = { "file", "change", "repository" },
  requires = { "local_path" },
  run = function(ctx, item)
    return ctx.native:reveal(item.target.local_path)
  end,
})
```

This makes “open in Finder” a small binding written by an adapter, not a
platform assumption baked into status, blame, or the Git executor. The action
can appear anywhere the item appears: a status entry, blame detail, commit
file list, or plugin-defined review surface.

### Events

Events describe state changes, not UI instructions. Initial event names are:

- `repository.updated`
- `action.started`
- `action.completed`
- `action.failed`
- `action.cancelled`

Payloads carry a repository, revision, and structured data. Clients should
refresh from a snapshot after a mutation instead of guessing the resulting Git
state from an event.

## Surfaces

CurrantGit has two especially important projections. They share the same core,
action registry, and navigation context. A projection may be a literal Neovim
buffer, a scratch/read-only buffer, or a virtual surface backed by semantic
lines and extmarks. The invariant is buffer-native interaction, not a specific
storage type.

### Repository sidebar

The repository view is a buffer-native sidebar/panel, not a dashboard. It
projects a snapshot into collapsible semantic sections such as:

- repository and branch metadata
- rebasing, cherry-picking, or conflict state
- untracked, unstaged, and staged files
- inline diffs and hunks
- pushed/unpushed and pulled/unpulled commits

Sections are semantic nodes with stable IDs. The surface supplies fold levels,
fold text, and a consistent collapse model whether it is implemented with
native folds, extmarks, or a virtual renderer. Actions remain contextual: `s`,
`u`, `=`, `dd`, `dv`, `<CR>`, `g?`, and their extensions all resolve through
the same action dispatcher.

The sidebar should refresh incrementally after an action and preserve cursor,
fold, and inline-diff state where the corresponding node still exists. A
plugin can add a namespaced section or projection without owning repository
state.

### Blame companion

Blame is a first-class source-linked surface, not just the output of a shell
command. Opening blame creates a companion view attached to an origin buffer:

```text
origin buffer  ◄── line mapping + scroll binding ──►  blame surface
                                                        │
                                                        ├─ open commit
                                                        ├─ reblame at commit
                                                        ├─ blame parent
                                                        └─ return to source
```

The blame model owns parsed lines, commit identity, source path, source line,
and optional origin metadata. The layout adapter decides whether that surface
is a right sidebar, horizontal split, tab, or preview. The default should feel
like Fugitive’s narrow synchronized split: source and blame scroll together,
the blame view does not steal source semantics, and closing it returns to the
origin buffer.

It should feel like a normal buffer. Users can move, search, yank, select,
collapse, and use ordinary Vim commands against it. Attribution is represented
as structured line data with extmarks and highlights, not as a bespoke widget
that intercepts basic interaction. The source buffer remains authoritative;
blame is a read-only projection with a stable mapping back to source lines.

This does not require every rich surface to be a literal buffer. A virtual
surface is valid when it preserves the same interaction contract: cursor
addressability, ranges, folds, mappings, search targets, yankable text, and
window lifecycle. The implementation can choose the lightest representation
that keeps those semantics intact.

The richer mode can progressively disclose context without making every line
wide and noisy:

```text
▌ 8f2c1ab  Maya Chen   2 weeks ago   src/window.lua:42
  local window = layout:open(spec)
```

- compact columns show commit, author, age, and source location
- a selected line can reveal subject, body, parents, and changed paths
- commit navigation opens the same shared revision/diff model as `Gdiff`
- optional inline attribution uses virtual text on the source buffer
- layout can switch between companion buffer, inline metadata, and detail
  preview without changing the blame model

Inline attribution is additive. It never rewrites source text, moves the
cursor’s semantic target, or becomes required for the companion view.

The initial blame actions are:

- `g?` — contextual help
- `<CR>` — open the commit and return to the source location
- `o` / `O` / `p` — open commit in split, tab, or preview
- `-` — reblame at the selected commit
- `~` / `P` — blame an ancestor or parent with an explicit count
- `A` / `C` / `D` — resize author, commit, or date columns
- `gq` — close blame and restore the source view

These are behavior targets, not a requirement to preserve Fugitive’s internal
buffer names, temporary files, Vimscript helpers, or layout hacks. A modern
implementation should use extmarks or explicit line mappings, window IDs, and
surface lifecycle state.

## Plugin model

Plugins are small adapters around public contracts. A plugin may provide one
or more of:

- actions, key sequences, and contextual help
- snapshot enrichers that add namespaced metadata
- buffer projections or panels
- event subscribers
- RPC methods and capabilities
- external service adapters

Registration is explicit during setup. Names are namespaced, capabilities are
declared, and teardown returns the registry to its prior state. The first
plugin API can be ordinary Lua modules; it does not need a plugin manager.

```lua
local currantgit = require("currantgit")

currantgit.setup({
  extensions = {
    require("my_review_extension"),
  },
})
```

The public module shape should stay small and pleasant to configure:

```lua
local currantgit = require("currantgit")

currantgit.setup({
  sidebar = { position = "right", width = 36 },
  blame = { position = "right", sync = true },
  actions = { discovery = true },
})
```

Feature modules should be lazy where possible and expose one clear setup or
registration function. Prefer `require("currantgit.blame")` and
`require("currantgit.actions")` over a deep public object graph. Keep defaults
opinionated, options narrow, and escape hatches explicit.

An extension should depend on `currantgit.actions`, `currantgit.events`, and
documented snapshot fields—not on renderer tables, buffer line offsets, or
private module paths. This is the seam that makes pluggability useful instead
of merely making internals public.

## RPC boundary

RPC exposes the same core capabilities to another process or UI. It is not an
arbitrary Lua bridge and it is not a shell proxy.

### Requests

```json
{
  "protocol": 1,
  "id": 42,
  "method": "action.stage_hunk",
  "params": {
    "repository": "/path/to/repo",
    "node_id": "working:App.swift:hunk:2",
    "expected_revision": 19
  }
}
```

### Responses

```json
{
  "protocol": 1,
  "id": 42,
  "result": {
    "ok": true,
    "revision": 20
  }
}
```

Errors are data, never prose scraped from a UI:

```json
{
  "protocol": 1,
  "id": 42,
  "error": {
    "code": "stale_revision",
    "message": "The repository changed before this action ran.",
    "data": { "current_revision": 20 }
  }
}
```

The protocol needs request IDs, protocol version, capability discovery,
snapshot revisions, cancellation, bounded message sizes, and structured
errors. Mutating requests should be safe to retry only when their action
contract says so. Clients must handle unknown fields and capabilities.

The first transport is an in-process adapter. Later transports can be
Neovim/MessagePack-RPC or a private Unix socket. Do not build a daemon until a
real second client proves that the boundary is useful.

## Security and authority

RPC may request named actions against an explicit repository. It may not:

- evaluate arbitrary Lua
- execute arbitrary shell text
- silently widen repository scope
- bypass action capability checks
- mutate through undocumented methods

`:Git` remains a user-facing escape hatch inside Neovim. That does not mean an
RPC client gets an implicit shell. If a future client needs arbitrary Git
commands, add an explicit, reviewable capability with clear progress,
cancellation, and output semantics.

## Extension lifecycle

1. Discover capabilities and protocol version.
2. Register namespaced actions, projections, or RPC methods.
3. Receive snapshots and events for repositories the extension opted into.
4. Invoke named actions with an expected revision when mutation matters.
5. Reconcile from the resulting snapshot.
6. Unregister cleanly on teardown or disconnect.

This keeps the core authoritative while allowing review panels, native clients,
automation, and future CurrantGit surfaces to grow independently.

## Decisions

- Keep Git CLI execution behind one executor first; do not start with libgit2.
- Keep RPC optional for the first user-facing release.
- Use the action registry as the shared source for mappings, discovery, and
  RPC.
- Make extensions consume stable semantic data, never rendered line offsets.
- Prefer additive, namespaced capabilities over a universal plugin interface.

These choices are deliberately modest. The point of the boundary is to let a
second client emerge without forcing the first client to carry a framework.
