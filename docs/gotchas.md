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
