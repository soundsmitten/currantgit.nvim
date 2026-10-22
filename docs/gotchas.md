# Gotchas

Concrete Git and Neovim landmines discovered the hard way while building
CurrantGit — verified empirically, not from memory. Check here before you
re-derive one of these from scratch, and add to it when you find a new one.
This is a knowledge base, not a policy: for the rules that follow from these,
see [`AGENTS.md`](../AGENTS.md) and [`development.md`](development.md)'s Git
safety doctrine. For the specific decisions made in response to some of
these, see [`decisions/`](decisions/).

## Git

- **`git status --short` renders a rename as one line**, `R  old -> new`.
  Slicing the path out of that line naively gives you the literal string
  `"old -> new"`, not a path. Use `git status --porcelain=v1 -z` instead —
  in `-z` output, a rename/copy entry is `to\0from\0` (destination first,
  `->` omitted, field order reversed from the human format) per
  `git help status`. See [`decisions/0004`](decisions/0004-status-parsing-uses-nul-delimited-porcelain.md).

- **A `---`/`+++` unified-diff header path is not always the raw filename.**
  Two independent Git mechanisms can transform it: (1) `core.quotePath`
  (default on) C-quotes/octal-escapes a path with "unusual" bytes -- and per
  `git help config`, double-quotes/backslash/control characters are
  *always* escaped this way regardless of that setting, while any byte above
  0x80 (i.e. any non-ASCII/unicode path) is escaped only under the default;
  (2) independently, a path containing a literal space gets exactly one
  literal trailing tab character appended (verified empirically: one tab
  regardless of how many embedded spaces), to disambiguate the path from a
  possible trailing text field in strict unified-diff format. Both can
  combine. There is no `-z`-equivalent for these header lines specifically —
  `-z` only changes `--raw`/`--numstat`/`--name-only`/`--name-status`
  output, not `diff --git`/`---`/`+++` lines (per `git help diff`). A parser
  extracting a hunk's real path from `+++ b/<path>` must undo both
  transformations, not assume the text after `b/` is the literal filename.
  See [`decisions/0011`](decisions/0011-unusual-path-diff-header-parsing.md).

- **Git's C-quoting of "unusual" path bytes uses the FULL C string-literal
  control-character escape set, not just `\t`/`\n`.** Verified empirically
  against real Git for every one of: `\a` (bell), `\b` (backspace), `\f`
  (form feed), `\n`, `\r` (carriage return), `\t`, `\v` (vertical tab) — plus
  `\"` and `\\`. A control byte with no named escape (e.g. 0x01) falls back
  to the 3-digit octal form (`\001`). An unquoting implementation that only
  special-cases the escapes its own test fixtures happened to exercise (a
  real mistake made and caught by independent review — see
  [`decisions/0011`](decisions/0011-unusual-path-diff-header-parsing.md)'s
  revision) will silently mangle a filename containing one of the others:
  `\r` decoding to the bare letter `r` instead of a carriage-return byte is
  exactly the kind of corruption of a stable identity field
  (`AGENTS.md` rule 6) this class of bug produces.

- **`-z` output is unquoted; the human format is not.** By default
  (`core.quotePath=true`), `git status`/`git diff` C-quote and
  octal-escape filenames containing tabs, newlines, quotes, backslashes, or
  most non-ASCII bytes in their human-readable output. `-z` output performs
  no quoting at all — raw bytes, NUL-terminated. If you're parsing Git
  porcelain output for real filenames, use `-z`, not string unescaping.

- **Non-conflict status codes can be built from the same letters as
  conflict codes.** The real "unmerged" codes are exactly `DD`, `AU`, `UD`,
  `UA`, `DU`, `AA`, `UU`. A pattern like `[DAU][DAU]` also matches `AD`
  (staged-add, then worktree-delete — a real, common, non-conflict state).
  Match the exact set, not a character class. See
  [`decisions/0007`](decisions/0007-exact-unmerged-status-code-set.md).

- **Git's default pathspec matching treats `*`, `?`, `[` as glob wildcards**,
  even for a plain literal filename you got back from `git status` (see
  `gitglossary(7)`, PATHSPECS). `git restore --worktree -- "a*file.txt"`
  against a repo containing both `afile.txt` and `a*file.txt` reverts both.
  Prefix a pathspec CurrantGit constructs itself with `:(literal)` to force
  an exact match. Do **not** apply this blanket rule to `:Git`'s raw
  user-typed arguments — that's an intentional escape hatch. See
  [`decisions/0002`](decisions/0002-literal-pathspecs-for-constructed-arguments.md).

- **`git blame`'s path argument is not a pathspec.** Its usage is
  `git blame [<rev-opts>] [<rev>] [--] <file>` — a single exact file, no
  glob expansion, no pathspec magic parsing at all. Prepending `:(literal)`
  to it *breaks* it (`fatal: no such path ':(literal)x' in HEAD`). Don't
  literal-guard blame's argument the way you would `add`/`restore`/`diff`.

- **`git blame --line-porcelain`'s per-line "group size" field is only on
  the first line of a same-commit run.** A parser that requires it on every
  line silently drops every subsequent line in that run. See
  [`decisions/0005`](decisions/0005-blame-porcelain-group-count-is-optional.md).

- **`git diff <rev>` and `git diff <rev1> <rev2>` are not "working tree
  diffs" for staging purposes**, even though neither passes `--cached`.
  Only a bare `git diff` (working tree vs index) or bare `git diff --cached`
  (index vs HEAD) is safe to build a `git apply --cached` action from. A
  historical two-revision diff can look identical to a live one and, if its
  "old" side happens to match the current index, silently create a phantom
  staged change when you "stage" one of its hunks. See
  [`decisions/0003`](decisions/0003-diff-mode-classification-for-hunk-mutation.md).

- **`git rev-parse --show-toplevel` (and any Git subprocess) without an
  explicit `cwd` uses the live process/editor working directory**, not
  whatever repository a buffer was originally opened against. If an action
  is scoped to a specific buffer/surface, pass its already-known root as an
  explicit `cwd`; don't re-resolve it from ambient state. See
  [`decisions/0001`](decisions/0001-buffer-scoped-actions-reuse-captured-root.md).

- **`git apply` is atomic by default.** `git help apply`: "For atomicity,
  git apply by default fails the whole patch and does not touch the working
  tree when some of the hunks do not apply." Verified this also holds for
  `--cached` (index-only) application: a patch whose context no longer
  matches the current index fails outright (non-zero exit, clear stderr) and
  leaves the index byte-for-byte unchanged — never a partial application.
  This only holds without `--reject`; CurrantGit's `stage_hunk`/`unstage_hunk`
  never pass `--reject`, so this guarantee applies to them.

- **`git apply --cached` only ever compares against the INDEX, never the
  working tree.** A hunk's patch text is generated once, when a diff is
  rendered. If the working tree changes again afterward but the index is
  still untouched, staging that (now visually stale) hunk still succeeds —
  it stages exactly what the diff showed at render time, not whatever the
  worktree contains now. This is correct, well-defined `git apply --cached`
  behavior, not data loss (the worktree's later edit is left completely
  alone) — but it means a CurrantGit diff buffer can go stale relative to
  the worktree without becoming stale relative to what it will actually
  stage. See
  [`decisions/0010`](decisions/0010-hunk-apply-edge-cases-verified-safe.md).

- **The bare `:<path>` object-specifier shorthand is ambiguous for a
  filename that itself starts with a digit 0-3 followed by a colon.**
  `git help gitrevisions`: `:[<n>:]<path>` optionally reads a leading stage
  number (0-3) and a colon before the path. For a real file named
  `2:file.txt`, `git show :2:file.txt` is parsed by Git itself as "stage 2,
  path `file.txt`" — not "stage 0, path `2:file.txt`" — and fails with a
  misleading "path does not exist" error. Use the explicit `:0:<path>` form
  instead: Git only strips one stage-number prefix, not a repeated one, so
  it resolves correctly even when the path itself starts with a
  digit-colon sequence. The `<rev>:<path>` form (e.g. `HEAD:<path>`) has no
  equivalent ambiguity — it takes everything after the first colon as the
  path unconditionally, regardless of what the path itself contains. See
  [`decisions/0012`](decisions/0012-open-deleted-explicit-index-stage.md).

- **A linked worktree's or a submodule's `.git` is a FILE, not a
  directory**, containing `gitdir: <path>`, pointing into the main
  repository's `.git/worktrees/<name>` (worktrees) or
  `.git/modules/<name>` (submodules). `git rev-parse --show-toplevel` run
  from inside either still correctly resolves to that worktree's/
  submodule's OWN working-directory root, not the main repository's --
  verified empirically, no special-casing needed in `repository_root()`.
  A submodule is a fully independent repository from Git's perspective:
  status/diff/stage all operate on it directly when run from inside it.

- **A submodule with uncommitted changes inside it cannot be staged from
  the parent repository at all, even though `git status` in the parent
  shows it as `M <name>`.** This is normal Git behavior, not a bug: the
  parent only ever tracks a submodule by its recorded commit SHA (the
  "gitlink"), and `git add <submodule-path>` has nothing to stage unless
  that recorded commit actually changed. A "dirty" submodule (uncommitted
  changes, same commit checked out) has no staged representation at the
  parent level -- staging only becomes possible once a real commit is made
  *inside* the submodule, which changes the gitlink the parent tracks. Don't
  mistake a silent, exit-0 no-op `git add` on a dirty submodule for a
  CurrantGit stage-action bug. See
  [`decisions/0013`](decisions/0013-worktrees-and-submodules-verified-safe.md).

- **A multi-file diff's *last* file having no `@@` hunk** (binary, pure
  mode/chmod change, 100%-similarity rename, empty file add/delete) is a
  normal, valid diff shape, not an edge case. A parser that assumes the
  last file always has a hunk will crash on it. See
  [`decisions/0006`](decisions/0006-diff-parse-tolerates-trailing-hunkless-file.md).

- **`git rev-parse --show-toplevel` itself fails cleanly (exit 128, `fatal:
  this operation must be run in a work tree`) inside a bare repository.**
  This means CurrantGit's `repository_root()` already refuses a bare
  repository before any status/diff/log/blame command is even attempted —
  no special bare-repo detection needed on top of the existing
  `repository_root()` failure check. Don't add redundant
  `--is-bare-repository` probing; verify first that the existing failure
  path doesn't already cover the case (see
  [`decisions/0009`](decisions/0009-bare-detached-unborn-verified-safe.md)).

- **`## HEAD (no branch)` and `## No commits yet on <branch>` are real,
  valid `git status --porcelain=v1 -z --branch` header lines** for detached
  HEAD and an unborn branch respectively — not malformed input. CurrantGit's
  status parser already passes them through as the branch display string
  as-is; no special-casing was needed once verified.

- **`git log`/`git blame` on an unborn branch (zero commits) fail with a
  real Git error** (`fatal: your current branch '<name>' does not have any
  commits yet` / `fatal: no such ref: HEAD`, both exit 128) rather than
  returning empty output. `git diff` on the same repo just succeeds with
  empty output (nothing to compare). All three are ordinary Git behavior a
  caller must be ready to see, not edge cases specific to this codebase.

## Neovim / test harness

- **A valid buffer ID does not make a saved cursor or window view valid after
  that buffer is reused.** A refreshed status, diff, or log projection may
  contain fewer or shorter lines than it did when `winsaveview()` and
  `nvim_win_get_cursor()` captured it. Before calling `winrestview()` or
  `nvim_win_set_cursor()`, clamp the saved line, byte column, and view fields
  against the buffer's current contents. Skip history entries whose buffers
  are no longer valid.

- **A Lua `nvim_create_user_command` callback's `args` field is the raw,
  unprocessed `<args>` text, not quote-aware.** `:help nvim_create_user_command()`
  documents `args` as "Args passed to the command, if any. `<args>`" — the
  quote-aware forms are the *separate* `<q-args>` (whole remainder as one
  expression-quoted string) and `<f-args>` (whitespace-split, individually
  quoted) escape sequences, neither of which a Lua callback receives. A
  plain `vim.fn.split(args, [[\s\+]], true)` on `command.args` will happily
  split `commit -m "two words"` into `{"commit", "-m", "\"two", "words\""}`.
  See [`decisions/0008`](decisions/0008-git-command-quote-aware-argument-splitting.md).

- **A synchronous `vim.notify(msg, ERROR)` (or `WARN`) inside a user-command
  callback re-raises as a Vim error (`E5108`) when that command is invoked
  through `vim.cmd()`/`nvim_exec2()`, but not when invoked through real
  cmdline key input (`nvim_feedkeys(":Cmd<CR>", "x", false)`).** This is an
  artifact of `nvim_exec2`'s error propagation for the invocation path, not
  of `vim.notify` itself or of how a real `:Cmd<CR>` keypress behaves. A test
  that drives a command expected to synchronously `vim.notify(ERROR)` should
  dispatch it via `nvim_feedkeys`, not `vim.cmd()`, or the test will see an
  uncaught Lua error instead of the graceful notification the real user
  sees.

- **Waiting on a buffer's `filetype`/a `vim.b` flag after triggering an
  async refresh can return before the refresh actually ran**, if the same
  buffer is being reused and already had that flag set from its *previous*
  render. This isn't just a test-authoring nitpick: it hid a real
  `.git/index.lock` collision, because two async Git processes ended up
  running against the same repository at once once an unrelated
  performance fix removed a blocking delay that had been accidentally
  masking the race. Wait on something that can only become true once the
  specific action finished — a buffer's `changedtick` increasing, a genuine
  buffer switch, or a semantic value changing — not a flag a stale render
  can already satisfy.

- **A valid buffer (`nvim_buf_is_valid` true) can still be unloaded**
  (`:bunload` without `!`, or any plugin freeing memory the same way), and
  `nvim_buf_line_count`/`nvim_buf_get_lines` report it as having 0 lines
  until something reloads it. `nvim_win_set_buf(window, buffer)` triggers
  that reload as a side effect. Reading line count/content to reconcile a
  saved cursor *before* switching the window to the buffer therefore
  measures the wrong (0-line) state; switch first, then reconcile against
  the now-loaded buffer.

- **`vim.b[buffer].some_table` returns a fresh copy on every index, not a
  live reference.** Mutating it in place (`local t = vim.b[buf].x; t.k =
  v`, or even the chained `vim.b[buf].x.k = v`) silently discards the
  change — confirmed empirically, it round-trips through the same
  serialize/deserialize boundary as any other `vim.b`/`vim.g`/`vim.w`
  access. To persist a change, build the new table value and assign it
  back with a direct `vim.b[buffer].x = new_table`.

- **A literal embedded NUL byte (`\0`) written directly into a Lua pattern
  string silently truncates the pattern**, even though the *subject* string
  being matched handles embedded NULs fine (e.g. `entry:sub(4)` on `-z`
  porcelain output). `("a\0b"):match("^(.-)\0(.*)$")` returns `("", nil)`
  instead of `("a", "b")` — confirmed empirically. Use the `%z` pattern
  class instead: `("a\0b"):match("^(.-)%z(.*)$")` correctly returns
  `("a", "b")`. This only affects the *pattern* argument; `\0` inside the
  string being searched, or inside a plain (non-pattern) `string.find`
  call, is unaffected.
