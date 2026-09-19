# 0008: `:Git` argument splitting is quote-aware, and refuses unterminated quotes

## Context

`:Git`'s Lua-callback `command.args` is Neovim's raw `<args>` value: the
unprocessed text typed after the command name, with no quote-aware
tokenization applied by Neovim before CurrantGit ever sees it (confirmed
against `:help nvim_create_user_command()` — the separate, escape-sequence
forms `<q-args>` and `<f-args>` are what apply any such processing, and
neither is what a Lua command callback receives as `args`). `split_args` used
to be `vim.fn.split(args, [[\s\+]], true)`: a pure whitespace split.

This broke any `:Git` invocation whose arguments contained a quoted string
with spaces. `:Git commit -m "two words"` produced
`{"commit", "-m", "\"two", "words\""}` instead of
`{"commit", "-m", "two words"}`. Verified against real Git in a disposable
repository: the resulting `git commit -m '"two' 'words"'` invocation failed
outright (`words"` was interpreted as an extra pathspec-like argument), so
the user's commit silently never happened.

## Decision

`split_args` now performs basic POSIX-shell-like word splitting:

- Single quotes are literal — no escape processing inside them.
- Double quotes allow `\"` and `\\` escapes; other backslashes inside double
  quotes are kept literally.
- A backslash outside quotes escapes the next character (lets a bare
  argument contain an escaped space or quote without full quoting).
- An unterminated quote is treated as malformed input. `split_args` returns
  `nil, error_message` in that case, and the `:Git` command handler refuses
  to run anything — no Git process is spawned — rather than guessing where
  the argument was meant to end (Git safety doctrine, principle 10: failure
  should be boring).

This is deliberately not a full shell-word-splitting implementation (no
`$VAR` expansion, no glob handling, no `$()`digital substitution) — those
are Git-safety-irrelevant shell features `:Git` never claimed to support, and
adding them would be scope creep past what fixes the actual bug. Reference:
vim-fugitive's `:Git`/`:G` command implements equivalent quote-aware
splitting for the same reason (`s:SplitExpandChain` in `autoload/fugitive.vim`);
this is a narrower, dependency-free version scoped to CurrantGit's needs.

## Consequences

- `:Git commit -m "two words"`, `:Git commit -m 'two words'`, and escaped
  double quotes inside a double-quoted argument all now produce the argv the
  user intended.
- An unterminated quote produces a clear, boring error and mutates nothing.
- User-typed `:Git` arguments are still Git's own escape hatch (per
  `docs/gotchas.md`'s pathspec-glob note) — this change only affects how the
  *command line itself* is tokenized into argv elements, not how Git
  interprets the resulting arguments once split.

## Revisit if

A user-reported case needs real shell semantics (variable expansion,
globbing) that this intentionally does not provide — that should be a
deliberate, documented escape hatch, not something this splitter grows
piecemeal.
