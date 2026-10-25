# 0015: Git's editor is routed into the running Neovim over RPC

## Context

`:Git commit` without `-m` (and `merge`, `tag -a`, `rebase -i`) needs an
editor. Git runs CurrantGit's commands with no terminal, so whatever editor
it found (`core.editor`, `$EDITOR`, `vi`) either exited at once ("Aborting
commit due to empty commit message") or could hang. Fugitive solves this by
making Git's editor talk back to the running Vim.

Building the message ourselves (`git commit -F`) was rejected: Git prepares
the template (merge messages, `commit.template`, `-v` diffs, rebase todo
lists), and re-creating that would drift from Git.

## Decision

The shared async executor sets `GIT_EDITOR` and `GIT_SEQUENCE_EDITOR` to
`nvim --headless --clean -l lua/currantgit/git_editor_shim.lua`, plus
`CURRANTGIT_SERVER=v:servername`. Git runs the shim with the file. The shim
connects to that server and calls `require('currantgit.git_editor').open()`,
which opens the file in a split with `bufhidden=wipe`. The shim polls
`state()` every 100 ms and exits 0 once the buffer is wiped, so Git reads
the file as the user left it. It exits 1 (Git aborts) if the file could not
be opened or the connection is lost.

Both paths are shell-quoted. `CURRANTGIT_SERVER` is passed explicitly
because `$NVIM` is documented only for `:terminal` and `jobstart()`, and
`vim.system`'s own docs contradict each other about it.

## Consequences

- Never run a Git command that might open an editor synchronously
  (`vim.system():wait()`): Git waits on the shim, the shim waits on this
  Neovim's main loop, and the main loop waits on Git. The bridge is only set
  in the async `execute`; the one synchronous call (`rev-parse
  --show-toplevel`) cannot open an editor.
- Without a server address the editor is `false`, so Git fails fast rather
  than starting a terminal editor with no terminal.
- Closing the buffer always hands the file back (exit 0), like a terminal
  `:q!`. There is no `:cq`-style abort; an empty message or todo is the abort
  path, which is Git's own rule.
- The shim calls into the parent with `nvim_exec_lua`. This is our own
  helper, not the extension RPC gateway, and it calls only the two named
  functions.

## Revisit if

Neovim gains a supported "wait for buffer" remote primitive, or users need a
distinct abort (a command that makes the shim exit 1).
