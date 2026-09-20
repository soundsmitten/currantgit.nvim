# Git safety audit — continuation brief (2026-09-19)

**Status:** Complete (2026-09-20, branch `codex/git-safety-audit-continuation`).
All seven items below were investigated against real, disposable Git
repositories. Three real bugs were found and fixed (items 1, 4/5 combined,
and 6); the rest were independently verified already safe with no code
change needed. See the main report's updated "Remaining dragons" and
"Guarantees" sections and `docs/decisions/0008`–`0013` for the resolution of
each item.

This is a work order for continuing
[`2026-09-19-git-safety-audit.md`](2026-09-19-git-safety-audit.md). Read that
report first — it has the environment, method, and the seven findings
already fixed in this pass, each with a matching ADR under `docs/decisions/`
and a regression test in `tests/safety.lua`. Read
[`../gotchas.md`](../gotchas.md) and the Git safety doctrine in
[`../development.md`](../development.md) before touching any of the items
below: several of the fixed findings look, on the surface, like small
parsing details, but were real data-loss or index-corruption bugs.

Treat every item below the same way the first pass did: **do not trust
reasoning about what Git would do — build a disposable repository under
`/tmp` and run the real command.** Consult `git help <subcommand>` for the
exact current behavior before assuming anything about output format,
argument semantics, or edge-case handling. This codebase has already shipped
multiple confidently-wrong assumptions about Git's behavior; verify, don't
assume (see `AGENTS.md` rule 1).

For every item you confirm and fix: write the regression test first against
the unfixed code, watch it fail for the right reason, then fix it and watch
it pass (`AGENTS.md` rule 14). Add the test to `tests/safety.lua` following
the existing pattern (a `make_repo()`/`write_file()`/`git()`-based helper
test function, called from the bottom of the file). Add a decision record
under `docs/decisions/` (numbered `0008` onward) for anything that would
otherwise be silently rediscovered or reversed by a later agent. Add a
`docs/gotchas.md` entry for the underlying Git/Neovim behavior itself. Run
`scripts/test` at least 3 times consecutively after each fix to catch
timing-sensitive regressions like Finding 7 in the main report — check for
leaked `nvim --headless` processes afterward
(`ps aux | grep "nvim --headless"`) and kill/clean up any that remain before
concluding a run was clean.

## Item 1 — `:Git` argument splitting is naive whitespace splitting

**File:** `lua/currantgit/init.lua`, `split_args(args)` (used by the `:Git`
user command to turn `command.args` into argv), currently
`vim.fn.split(args, [[\s\+]], true)`.

**Why this is suspicious:** this splits purely on whitespace, with no
awareness of quoting. `:Git commit -m "two words"` would very plausibly
split into `{"commit", "-m", "\"two", "words\""}` instead of
`{"commit", "-m", "two words"}`, silently breaking any `:Git` invocation
whose arguments contain a quoted string with spaces.

**What's unverified:** whether Neovim's command-line parsing for
`nargs = "*"` already does some quote-aware tokenization on `command.args`
before `split_args` ever sees it (in which case this might be a non-issue,
or a double-splitting issue) — this needs checking against current Neovim
docs (`:help nargs`, `:help command-args`, `:help <q-args>`) rather than
assumed.

**How to verify:** open a real Neovim instance (headless is fine), run
`:Git commit -m "two words"` against a fixture repo with something staged,
and inspect the actual `args` table `split_args` receives (e.g. temporarily
print it, or write a headless script that captures `M.git`'s argument via a
stub). Confirm whether the commit message actually ends up as `"two words"`
in `git log` or gets mangled.

**If broken:** implement proper shell-word splitting (Neovim has
`vim.fn.shellescape`/no direct "shell split" builtin as far as is currently
known — check `:help` for the current API before assuming one exists or
writing one from scratch) and add a regression test that a quoted
multi-word `:Git commit -m "..."` produces exactly that message.

## Item 2 — Bare repositories, detached HEAD, unborn branches

**Why this matters:** none of `open_status`, `open_diff_args`, `open_log`,
or `open_blame` have been exercised end-to-end (through actual CurrantGit
buffers, not just raw `git` commands) against:

- a bare repository (`git init --bare`) — CurrantGit should probably refuse
  cleanly rather than attempt a status/diff that assumes a working tree;
- a detached HEAD (`git checkout --detach <rev>`) — status's `## HEAD (no
  branch)` header format was captured during this audit but never exercised
  through `parse_status`'s branch-display logic;
- an unborn branch / empty repository with no commits yet (`git init` with
  no commits) — status's `## No commits yet on <branch>` header format was
  captured during this audit but never exercised through
  `parse_status`, and `open_log`/`open_blame`/`open_diff` against a
  repository with zero commits have never been tried at all (do they error
  cleanly, hang, or crash?).

**How to verify:** build one disposable fixture per case, open `:Git`,
`:Git log`, `:Git diff`, and (where applicable) `:Git blame <file>` against
each, and confirm CurrantGit either behaves correctly or fails with a clear,
boring error — never a crash, and never a misleading empty/wrong render.

## Item 3 — `git apply` edge cases for hunk stage/unstage

**Why this matters:** `stage_hunk`/`unstage_hunk` run
`git apply --cached --unidiff-zero [--reverse]` against a hunk's own patch
text, constructed by `diff.lua`'s `hunk.patch` field. None of the following
have been tested:

- a file with no trailing newline at EOF (Git represents this with a
  `\ No newline at end of file` marker line in the diff — does
  `diff.lua`'s patch reconstruction handle that marker correctly, or does it
  get treated as ordinary content / break the patch?);
- staging one hunk out of several in the same file, then staging a second
  hunk whose context now doesn't match because the first stage already
  changed the index — does `apply --cached` correctly still find context, or
  does `--unidiff-zero` (zero context) make this a non-issue by construction
  (worth confirming from `git help apply` directly, not assumed);
- a hunk-apply that fails partway — is the failure atomic (index completely
  unchanged) or can it leave a partial/corrupt index state? `git apply`'s
  own atomicity guarantees for `--cached` should be checked in
  `git help apply` rather than assumed;
- a hunk that no longer applies at all because the underlying file changed
  since the diff was rendered (stale hunk) — does CurrantGit refresh before
  allowing the action, detect the failure and refuse cleanly, or silently
  do nothing while claiming success?

**How to verify:** build fixtures for each case above, drive the actual
`stage_hunk`/`unstage_hunk` action through the UI (not just `git apply`
directly), and snapshot repository state before/after per the Git safety
doctrine's blast-radius-test principle.

## Item 4 — Unusual-but-valid paths end-to-end

**Why this matters:** Finding 6 in the main report fixed *parsing* of
unicode/tab/quote-containing filenames (via the `-z` switch), but no test
exercises the full action chain — stage, unstage, discard, diff, open,
blame — against a real file with a unicode name, an embedded space, or a
leading `-` (which some tools misparse as a flag). `:(literal)` pathspec
guarding (Finding 2) should make these safe, but "should" is exactly the
word this audit's doctrine says not to trust without a real repro.

**How to verify:** build a fixture with files named e.g. `café.txt`,
`file with spaces.txt`, and `-dashfile.txt`, all modified, and drive every
action against each through the real UI. Confirm no action targets the
wrong file and no action fails in a way that looks like success.

## Item 5 — `open_diff_args`'s single-pathspec extraction

**File:** `lua/currantgit/init.lua`, inside `open_diff_args`:
```lua
local path
for index, arg in ipairs(args) do
  if arg == "--" then path = args[index + 1] end
end
```
This only captures one path immediately after `--`. `:Git diff -- a.txt
b.txt` (two pathspecs) would only ever record `a.txt` as `options.path`,
which `diff.lua` uses as a fallback path when a hunk's own header can't
supply one (e.g. via `+++ b/<path>` extraction). Check whether this
fallback path is ever actually reached in a multi-pathspec diff (each
hunk's own header should normally supply the real per-hunk path), and if
so, what goes wrong. This is LOW severity unless proven otherwise — verify
before spending time on a fix.

## Item 6 — `open_deleted`'s colon-in-filename ambiguity

**File:** `lua/currantgit/init.lua`, `open_deleted`, which builds a Git
revision/object specifier as `revision .. ":" .. item.path` (i.e.
`<rev>:<path>` syntax for `git show`). A real filename containing a literal
`:` character would make this ambiguous or wrong. Check `git help
gitrevisions` / `git help git-show` for the exact disambiguation rules
around `:` in this syntax before assuming it's broken or safe — this is a
real but narrow edge case (LOW priority) since `:` is rare in filenames.

## Item 7 — Worktrees and submodules

Not investigated at all in this pass. Before doing anything else here,
check whether `repository_root()`'s `git rev-parse --show-toplevel` and the
rest of CurrantGit's repository-discovery logic behave sanely when run from
inside a linked worktree or a submodule's own working tree — both change
what "the repository" means relative to `.git` being a file vs. a directory.
Consult current Git documentation (`git help worktree`, `git help
submodule`) rather than assuming past knowledge is current.

## When you're done

Update the main audit report's "Remaining dragons" and "Guarantees" sections
to reflect what's now covered, following the same honest,
narrowly-scoped-claims style — don't upgrade a guarantee until it's been
independently verified the same way everything else in that report was.
Perform a final fresh adversarial pass over the *whole* plugin (not just
this continuation's items) before considering the audit closed, per the
original audit's closing instruction: repository integrity outranks feature
completeness, and the agent that fixed something doesn't get the final word
on whether it's actually fixed.
