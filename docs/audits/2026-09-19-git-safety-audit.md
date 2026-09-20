# Git safety audit — 2026-09-19

**Status:** Complete for the scope below, plus the continuation scope in
[`2026-09-19-git-safety-audit-continuation.md`](2026-09-19-git-safety-audit-continuation.md),
which is also now complete (branch `codex/git-safety-audit-continuation`,
2026-09-20). Three more findings were fixed during the continuation pass
(`:Git` argument splitting, `hunk.path` corruption for quoted/tab-suffixed
diff headers, and `open_deleted`'s ambiguous index-object shorthand); bare
repositories, detached HEAD, unborn branches, `git apply` edge cases,
unusual-but-valid paths, and worktrees/submodules were all independently
verified already safe. See `docs/decisions/0008`–`0013` and the updated
"Remaining dragons"/"Guarantees" sections below.

**Scope:** a comprehensive correctness/safety audit of CurrantGit's Git
mutation and parsing surfaces — status/index/worktree semantics, diff and
hunk staging, discard, blame, and the repository-root/pathspec/revision
handling underneath all of them. Framed from the start as an adversarial
review that must independently verify every claim against real Git, not
CurrantGit's own interpretation of it, per the doctrine in
[`../development.md`](../development.md).

**Environment:** Git 2.50.1 (Apple Git-155), Neovim v0.12.4, macOS (darwin).
Branch: `codex/log-surface` at commit `228434b` (pre-audit baseline).

**Upstream documentation consulted (primary source, not memory):**

- `git help status` — Short Format and Porcelain Format Version 1 sections,
  specifically the `-z` field-order and quoting contract for renames/copies.
- `git help blame` — `--line-porcelain` output format and the `<file>`
  argument's usage grammar.
- `git help diff` — `--cached`/`--staged` semantics and revision-argument
  forms.
- `git help restore`, `git help apply` — pathspec and patch-application
  semantics.
- `gitglossary(7)` — the PATHSPECS section, specifically default fnmatch
  glob-magic behavior and the `:(literal)` magic signature.

## Method

Every finding below was independently reproduced against a real, disposable
Git repository under `/tmp` before being treated as confirmed — not inferred
from reading the implementation. Where a fix was made, the fix was
re-verified the same way, through CurrantGit's actual code path (not just
the underlying `git` command), before being considered closed. Existing
test-suite coverage was also treated as a claim to verify, not evidence in
itself; see Finding 7, which is a bug in the test harness that the rest of
this audit's own new tests originally reproduced by accident.

## Findings

### 1. Cross-repository cwd-race data loss — CRITICAL

**Behavior:** `action_context(buffer)`'s inner `action()` closure re-derived
the repository root via a fresh, live `repository_root()` call (which shells
out using the editor's current working directory) instead of reusing the
root the buffer was actually opened against. Stage, unstage, discard, and
hunk-apply actions are asynchronous — discard additionally waits on
`vim.ui.select` for confirmation — so a `:cd` into a different repository
during that gap redirected the Git mutation to the wrong repository, using a
pathspec that was only ever valid relative to the original one.

**Why wrong:** a CurrantGit surface's identity must be stable regardless of
ambient editor state (Git safety doctrine, principle 5).

**Authoritative source:** `git rev-parse --show-toplevel` resolves relative
to the process's current working directory when no `-C`/`cwd` is given —
there is no repository-scoping built into the Git invocation itself; that
scoping is CurrantGit's responsibility.

**Minimal repro:** two disposable repos, A and B, each with an unrelated
uncommitted change to a same-named file. Open `:Git status` in A, press `X`
(discard) on the file, stub `vim.ui.select` to answer after a short delay,
and `:cd` into B before the delay elapses. Before the fix: B's unrelated
change was silently reverted. After the fix: A's change reverts correctly
and B is untouched.

**Fix:** [`decisions/0001`](../decisions/0001-buffer-scoped-actions-reuse-captured-root.md).
Actions dispatched from an existing buffer now reuse that buffer's captured
root; only top-level command dispatch (`:Git`, `:GitActivity`) resolves root
fresh.

**Regression test:** `tests/safety.lua`, `test_cwd_race`.

### 2. Pathspec glob-magic collateral damage — CRITICAL

**Behavior:** Stage (`git add -- <path>`), unstage
(`git restore --staged -- <path>`), discard
(`git restore --worktree -- <path>`), and item-diff (`git diff -- <path>`)
passed a literal filename straight through as an unguarded pathspec.

**Why wrong:** Git's default pathspec matching treats `*`, `?`, and `[` as
fnmatch wildcards. A real file named `a*file.txt` used as a pathspec can
match and mutate an unrelated file like `afile.txt`.

**Authoritative source:** `gitglossary(7)`, PATHSPECS.

**Minimal repro:** a repo with tracked files `afile.txt` and `a*file.txt`,
both modified. `git restore --worktree -- "a*file.txt"` (exactly what
discard constructed) reverted both files.

**Fix:** [`decisions/0002`](../decisions/0002-literal-pathspecs-for-constructed-arguments.md).
CurrantGit-constructed pathspecs are prefixed with Git's `:(literal)`
pathspec-magic signature. `git blame`'s path argument is deliberately
excluded — it isn't a pathspec, and `:(literal)` breaks it outright.
User-typed `:Git` arguments are also deliberately excluded — that's an
intentional escape hatch with normal Git semantics.

**Regression test:** `tests/safety.lua`, `test_glob_pathspec`.

### 3. Diff mode-trust / phantom staged changes — CRITICAL

**Behavior:** A diff's hunk-stage eligibility was decided by checking
whether `--cached` was present in the raw arguments. Any diff comparing
two arbitrary revisions (`:Git diff <rev1> <rev2>`, or even a single
`:Git diff <rev>`) doesn't pass `--cached` either, so it was classified the
same as a genuine working-tree-vs-index diff, making "stage hunk" available.

**Why wrong:** staging a hunk runs `git apply --cached` against the *live
index*. If a purely historical diff's "old" side happens to match the
current index (very plausible for a file that hasn't changed recently),
staging one of its hunks silently applies unrelated historical content to
the real index.

**Authoritative source:** `git help diff` (revision-argument forms; only a
bare `git diff` compares working tree to index, and only a bare
`git diff --cached`/`--staged` compares index to HEAD).

**Minimal repro:** three commits on one file (`a` → `b` → back to `a`,
HEAD clean). `:Git diff <first> <second>` (a pure historical, two-revision
diff unrelated to the working tree) shows a `-a/+b` hunk. Pressing `s`
(stage) on it — before the fix — changed `git status --short` from clean to
`MM file.txt`, with `b` now staged, from a repository that had no
uncommitted changes at all.

**Fix:** [`decisions/0003`](../decisions/0003-diff-mode-classification-for-hunk-mutation.md).
A diff is only ever classified `"working"` (bare `git diff`) or `"staged"`
(bare `git diff --cached`/`--staged`); everything else, including any single
or double revision argument, is `"historical"` and offers neither
`hunk.stage` nor `hunk.unstage`.

**Regression test:** `tests/safety.lua`, `test_diff_mode_trust`.

### 4. Blame line-dropping — HIGH

**Behavior:** `blame.parse`'s header regex required a trailing group-size
field on every `--line-porcelain` header line. Real Git output only emits
that field on the *first* line of a contiguous same-commit run; every
subsequent line in the run has three fields, not four. The regex silently
failed to match those lines, and the parser dropped their entire
author/summary/text record.

**Why wrong:** dropped rows desync the `row.line`-based CursorMoved mapping
between the blame companion buffer and the source buffer for every line
after the first drop in any multi-line same-commit block — an extremely
common case, not an edge case.

**Authoritative source:** `git help blame`, `--line-porcelain`.

**Minimal repro:** a single commit with 5 lines. Before the fix, only line 1
survived parsing; lines 2–5 were silently gone.

**Fix:** [`decisions/0005`](../decisions/0005-blame-porcelain-group-count-is-optional.md).

**Regression test:** `tests/safety.lua`, `test_blame_multiline`.

### 5. `diff.parse` crash on a trailing hunkless file — HIGH

**Behavior:** the parser's finalization step unconditionally indexed
`current_hunk`, which is `nil` whenever the *last* file in a multi-file diff
has no `@@` hunk (binary file, pure mode change, 100%-similarity rename,
empty file) while an earlier file did have one.

**Why wrong:** this is a normal, valid diff shape, not pathological input.
The crash is caught by the surrounding `xpcall` and surfaced as an error
notification rather than corrupting anything, but it fully blocks viewing or
staging any changeset that happens to end in such a file.

**Minimal repro:** a two-file diff, first file has a text hunk, second file
is binary-only (no hunk). `diff.parse` raised
`attempt to index local 'current_hunk' (a nil value)`.

**Fix:** [`decisions/0006`](../decisions/0006-diff-parse-tolerates-trailing-hunkless-file.md).

**Regression test:** `tests/safety.lua`, `test_diff_trailing_binary`.

### 6. Status rename corruption + non-conflict status-code misclassification — MEDIUM

**Behavior, part A:** `git status --short`'s human format renders a staged
rename as one line, `R  old.txt -> new.txt`. The parser took everything
after the status code as a single path, producing the literal string
`"old.txt -> new.txt"` — not a real path — for every renamed file's `item`.
Every action built from `item.path` (stage, unstage, discard, diff, open)
then operated on a pathspec that matched no real file: `diff` silently
no-op'd, stage/unstage/discard failed cleanly with a Git error (repository
left unchanged, but the feature was completely non-functional for renames).

**Behavior, part B:** conflict detection used the character-class guess
`status:find("[DAU][DAU]")`, which also matches real non-conflict codes
built from the same letters, most notably `AD` (staged-add, then
worktree-delete). Such files were misclassified into a phantom "Conflicts"
section with the wrong `change_kind`.

**Authoritative source:** `git help status`, Porcelain Format Version 1
(`-z` field order and quoting) and the Short Format status-code table
(exact unmerged codes: `DD`, `AU`, `UD`, `UA`, `DU`, `AA`, `UU`).

**Minimal repro (A):** `git mv old.txt new.txt` (staged) plus an unstaged
edit produced status `RM old.txt -> new.txt`; the parsed item's `path` was
the whole string. **Minimal repro (B):** `git add` a new file, then remove
it from the worktree without restaging, producing status `AD`; the item was
placed in "Conflicts."

**Fix:** [`decisions/0004`](../decisions/0004-status-parsing-uses-nul-delimited-porcelain.md)
(switch to `git status --porcelain=v1 -z --branch`, parse the NUL-delimited
stream, and expose `old_path` separately from `path`) and
[`decisions/0007`](../decisions/0007-exact-unmerged-status-code-set.md)
(match the exact seven unmerged codes instead of a character class). The
`-z` switch also incidentally fixes unicode/tab/quote-containing filenames,
which the old human format would have C-quoted and the parser never
unquoted.

**Regression test:** `tests/safety.lua`, `test_status_rename_and_status_codes`.

### 7. Test-harness async-wait race (found during this audit's own verification) — process finding

**Behavior:** several `scripts/test` waits checked a reused buffer's
`filetype`/`vim.b.currantgit_title` after triggering a refresh. On a buffer
that already had that value set from its *previous* render, the wait could
return before the new async refresh actually finished. This was not
theoretical: removing an unrelated, unnecessary blocking `repository_root()`
call (part of Finding 1's fix) shifted timing enough that two async `git`
processes ended up racing for the same `.git/index.lock`, causing real,
reproducible `scripts/test` failures.

**Why it matters:** the existing test suite's own refresh-related assertions
were not proving what they appeared to prove, and a similar bug in
`tests/safety.lua` itself (written during this audit) reproduced the exact
same failure mode before being caught.

**Fix:** waits on refresh completion now check for a buffer-identity change
or `changedtick` increase, not just a flag value. See
[`../gotchas.md`](../gotchas.md) and `AGENTS.md` working rule 14.

## Fixes made

| File | Change |
|---|---|
| `lua/currantgit/init.lua` | Root-threading for `open_status`/`open_diff_args`/`open_diff`/`open_deleted`/`open_blame`/`action_context`; `:(literal)` pathspec guards; `classify_diff_mode`; NUL-delimited status parsing; exact unmerged-code set; rename `old_path` field and display. |
| `lua/currantgit/diff.lua` | Guarded `current_hunk.end_line` finalization; changed the unset-mode default from `"working"` to `"historical"`. |
| `lua/currantgit/blame.lua` | Dropped the mandatory trailing group-size field from the header regex. |
| `tests/smoke.lua` | Replaced two racy `filetype`-only refresh waits with a changedtick-aware helper. |
| `tests/safety.lua` (new) | Six regression tests, one per finding above (1–6), all built on disposable real Git repositories with independent verification of both the requested change and the absence of collateral damage. |
| `AGENTS.md`, `CONTRIBUTING.md`, `README.md`, `docs/development.md` | Git safety doctrine, two-phase implementation/adversarial-validation workflow, pointers to the new `docs/gotchas.md` and `docs/decisions/`. |
| `docs/decisions/0001`–`0007` (new) | One ADR per finding above with a fix, each with context/decision/consequences/revisit-if. |
| `docs/gotchas.md` (new) | The concrete Git/Neovim landmines behind the findings, for future agents to check before rediscovering them. |

## Regression coverage

`tests/safety.lua` adds six end-to-end tests, each against a disposable real
Git repository (not a mock), each independently re-deriving ground truth
from `git` itself or the filesystem rather than trusting CurrantGit's own
projection of what happened. Verified green across 5+ consecutive runs of
the full `scripts/test` harness (`contract validation` → `log` → `safety` →
`smoke`) with zero leaked background processes.

## Remaining dragons

Updated 2026-09-20 after the continuation pass (see
[`2026-09-19-git-safety-audit-continuation.md`](2026-09-19-git-safety-audit-continuation.md)
and `docs/decisions/0008`–`0013` for how each item below was resolved).

Resolved by the continuation pass, no longer dragons:

- `:Git`'s argument splitting was naive whitespace splitting with no
  shell-quote awareness — **fixed**, now quote-aware with a clean refusal
  on an unterminated quote (decision 0008).
- Bare repositories, detached HEAD, and unborn branches had not been
  exercised end-to-end — **verified already safe**, no code change needed
  (decision 0009).
- `git apply`'s context/atomicity/no-trailing-newline/stale-hunk behavior
  for hunk stage/unstage had not been adversarially tested — **verified
  already safe**, no code change needed (decision 0010).
- Unusual-but-valid paths (unicode, embedded spaces, leading `-`) had not
  been exercised end-to-end — **a real bug was found and fixed**: quoted
  and tab-suffixed diff headers corrupted `hunk.path` (decision 0011).
- `open_diff_args`'s single-pathspec fallback extraction — **verified
  practically unreachable** for real `git diff` output once the header-path
  extraction fix above is in place; every hunk gets its own real path from
  its own header regardless of which pathspec was passed (decision 0011).
- `open_deleted`'s `<rev>:<path>` colon-in-filename ambiguity — **a real bug
  was found and fixed**: the bare `:<path>` shorthand is genuinely ambiguous
  for a filename starting with a digit 0-3 and a colon (decision 0012).
- Worktrees and submodules — **verified already safe**, no code change
  needed; a "dirty submodule can't be staged from the parent" behavior was
  confirmed to be normal Git semantics, not a bug (decision 0013).

Still open, out of scope for both passes so far:

- `git apply`'s behavior for a hunk that *partially* applies with
  `--reject` has not been tested (CurrantGit never passes `--reject`, so
  this is currently moot, but would need its own verification if that ever
  changed).
- No fuzz/property-based testing of the status/diff parsers against
  arbitrarily malformed or adversarially crafted Git output (only real,
  valid Git output shapes have been exercised).
- RPC/provider-facing surfaces (`lua/currantgit/rpc.lua`) have not been
  through a dedicated adversarial pass of their own.

## Guarantees CurrantGit can and cannot make

**Can, as of the continuation pass (2026-09-20):** everything from the
original pass below, plus: `:Git` commands with quoted multi-word arguments
(single- or double-quoted, including escaped double quotes) are tokenized
correctly, and an unterminated quote is refused cleanly with no Git process
spawned; a bare repository refuses cleanly at the first step with no crash
or phantom surface; detached HEAD and an unborn branch both render and
behave correctly for status/diff, with log/blame failing as clean, expected
Git errors on an unborn branch; hunk stage/unstage correctly handles a
missing trailing newline, sequential multi-hunk staging, and fails
atomically (index untouched) when a patch's context no longer matches;
stage/unstage/diff/blame/discard/open all work correctly for unicode,
embedded-space, and leading-dash filenames, and a hunk's `path` field is the
real filename even when Git quotes or tab-suffixes it in the diff header;
`open_deleted` resolves correctly even for a filename that itself looks like
an index stage-number prefix; CurrantGit works correctly from inside a
linked worktree (and cannot leak a mutation into the main repository's own
worktree) and from inside a submodule's own working copy.

**Original pass (2026-09-19):** a CurrantGit surface stays pinned to the
repository it was opened from regardless of later `:cd`s; stage, unstage,
and discard on a literal filename cannot collaterally mutate a
similarly-named file; hunk staging cannot silently apply an unrelated
historical patch to the live index; blame attribution is complete for
same-commit line runs; a diff ending in a binary/mode-only/pure-rename file
does not crash the plugin; renamed files are addressable and actionable by
their real current path; non-conflict staged-add/worktree-delete files are
not shown as merge conflicts.

**Cannot yet claim:** correctness under `git apply --reject` partial
application (not used by CurrantGit today, so not currently a live risk);
robustness against malformed/adversarially-crafted Git output beyond real,
valid Git output shapes; anything about the RPC/provider surface's own
Git-safety properties, which has not had a dedicated adversarial pass. These
are the dragons above, not silent gaps.
