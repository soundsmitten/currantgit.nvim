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

## Git safety doctrine

CurrantGit's core promise is buffer-first Git that people can trust with real
work. That promise is decided at the Git boundary: the point where
CurrantGit's model of a repository, a path, a revision, or a patch meets
Git's own interpretation of the same thing. A locally reasonable assumption
there can become a destructive operation, because Git parses repository
identity, revisions, pathspecs, patches, and index/worktree state on its own
terms, not CurrantGit's.

High-velocity autonomous implementation is genuinely useful. It is not, by
itself, evidence that a Git-facing change is correct. Neither is an
implementation-authored test suite that stays green — a test that only
exercises CurrantGit through CurrantGit's own interpretation can reproduce the
exact wrong assumption it is supposed to catch. The agent that built a change
does not get the final word on whether it is safe.

1. Repository integrity outranks everything else. Feature completeness,
   velocity, convenience, backward compatibility, and cleverness all yield to
   it.
2. The implementation is not its own oracle. Mutation-sensitive correctness is
   established by observing real Git, in a real repository, independently of
   what CurrantGit believes happened.
3. Green tests are necessary, not sufficient. New Git-facing behavior earns
   adversarial fixtures, negative assertions, unusual-but-valid repository
   states, and deliberate failure paths — and each test should prove both
   that the requested change happened and that nothing else did.
4. Mutation authority is explicit and semantic. Offer an action only when
   CurrantGit actually understands the state or comparison it represents.
   Never infer permission from presentation details, incidental arguments, or
   buffer shape. When in doubt, refuse.
5. Repository identity is stable. A surface, and any action pending against
   it, belongs to the repository it was opened from. It must not silently
   retarget because the working directory, window, or tab changed underneath
   it.
6. User-controlled Git input stays what the user meant. Paths, revisions,
   pathspecs, refs, patches, and arguments must not acquire Git semantics the
   user never asked for while crossing a command boundary. Git's own parsing
   rules are part of the safety model, not an implementation detail to
   ignore.
7. Prefer explicit, machine-readable Git contracts. Porcelain and plumbing
   formats meant to be parsed, NUL-delimited output, explicit format strings,
   and literal path handling beat scraping human-oriented text.
8. Valid Git weirdness is normal input, not an edge case. Renames, conflicts,
   detached HEAD, unborn branches, worktrees, binary files, unusual
   filenames, mode changes, symlinks, and mixed staged/unstaged state all
   happen in real repositories. Handle them correctly, or say plainly that
   they are unsupported. Never guess.
9. Destructive operations require blast-radius tests. Discard, stage,
   unstage, hunk application, and recovery paths need tests that
   independently confirm unrelated working-tree content, index state,
   untracked files, and repository identity survived. Snapshot before,
   compare after.
10. Failure should be boring. Invalid, stale, unsupported, malformed, or
    ambiguous state should produce a clear refusal or error and leave the
    repository unchanged. A crash is a bug. Mutating the wrong thing is
    worse.
11. Independent adversarial review is part of the loop, not an afterthought.
    A review pass over Git-mutating surfaces should try to falsify
    assumptions, not confirm that the implementation looks reasonable. It
    does not take the implementation's tests, docs, or prior review at its
    word — it reproduces claims empirically, in disposable repositories,
    against real Git.
12. Agents are expected to disagree with previous agents. Agent-assisted
    development is not an exercise in accumulating agreement. A reviewing
    agent treats earlier work as evidence, not as settled fact: reproduce the
    important claims, check the upstream contract, look for the
    counterexample, and notice when the implementation and its own tests
    share the same blind spot. Constructive disagreement, resolved
    empirically, is the point.
13. Safety findings become permanent regression knowledge. When an audit
    finds a bug, patching the observed example is not the fix. Name the
    invariant it violated, look for the sibling cases, add regression
    coverage that would catch the whole class, and record the finding where
    a later agent will actually see it before repeating it: the concrete
    Git/Neovim behavior goes in [`docs/gotchas.md`](gotchas.md), and any
    decision that would otherwise be silently rediscovered or reversed goes
    in a numbered record under [`docs/decisions/`](decisions/).
14. Here be dragons, and that is fine to say out loud. Some Git behavior is
    too ambiguous, or insufficiently validated, to expose yet. Mark that
    boundary honestly instead of quietly shipping past it. Unsupported is
    acceptable. Unsafe-but-convenient is not.

None of this makes CurrantGit incapable of losing someone's work. It describes
the standard the project holds itself to, and the process meant to catch the
gap between that standard and what actually shipped.

## Adversarial validation

Any change that touches repository identity, revisions, pathspecs, patches, or
index/worktree state goes through two conceptually separate phases, even when
the same agent performs both.

**Implementation** — investigate, implement, add tests, document the
behavior, and get the normal harness green.

**Adversarial validation** — distrust the implementation. Consult the
authoritative Git (and, where relevant, Neovim) contract for every operation
involved, rather than relying on memory or on what the implementation
assumed. Build independent fixtures in disposable repositories and try to
falsify the change's assumptions. Deliberately exercise failure paths and
measure blast radius: what happens to everything the change was not supposed
to touch. Inspect the resulting Git state directly, not through CurrantGit's
own reporting of it. Fix what breaks, and add the regression before moving
on.

An independent reviewing context is preferred for the second phase whenever
one is available, because the implementer's own assumptions are themselves
part of what needs checking — a shared blind spot does not get caught by
asking the same mind to look twice. When only one agent is available, the
change still gets a genuinely adversarial second pass, not a confirmation
pass.

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

Help is part of the same loop. Add or update `doc/currantgit.txt` when a public
command, action, configuration option, or CurrantGit-specific interaction
changes. Do not duplicate obvious built-in Vim behavior; document the local
extension and its boundary with the editor instead.

Configuration follows the same discipline: defaults should be useful, options
should be few, and every documented option should affect observable behavior.
Do not expose an option merely to avoid choosing a default.
