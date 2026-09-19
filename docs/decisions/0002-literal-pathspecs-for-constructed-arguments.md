# 0002: CurrantGit-constructed pathspecs are literal, except for `git blame`

## Context

Git treats `*`, `?`, and `[` in a pathspec as fnmatch wildcards by default
(see `gitglossary(7)`, PATHSPECS). CurrantGit builds pathspecs from real,
literal filenames parsed out of `git status` — a filename containing one of
those characters is a real, if unusual, filename, not a pattern the user
asked to expand.

This was verified empirically: with two tracked files `afile.txt` and a
literally-named `a*file.txt`, both modified, running
`git restore --worktree -- "a*file.txt"` (exactly what the discard action
constructed) reverted *both* files. Discarding the file the user selected
silently destroyed unrelated uncommitted work in a file they never touched.

Git's pathspec magic supports a `:(literal)` short-form prefix that disables
wildcard interpretation for that pathspec. It was verified directly against
the installed Git that `:(literal)` correctly restricts `git add`,
`git restore --staged`, `git restore --worktree`, and `git diff --` to an
exact literal path.

`git blame` was checked separately and behaves differently: its path
argument is not a pathspec at all (usage is
`git blame [<rev-opts>] [<rev>] [--] <file>`, a single exact file, not a
pathspec list), it performs no glob expansion on it, and prepending
`:(literal)` to it fails outright (`fatal: no such path ':(literal)x' in
HEAD`) because blame does not parse pathspec magic syntax.

## Decision

Every pathspec CurrantGit itself constructs from a parsed item — stage,
unstage, discard, and the item-based diff — is prefixed with `:(literal)`
before being passed to Git. `git blame`'s path argument is passed as-is,
with no `:(literal)` prefix and no other pathspec-magic handling, because it
isn't a pathspec.

Raw, user-typed `:Git <subcommand> ...` arguments (the `:Git` escape hatch)
are **not** touched by this decision. A user typing `:Git diff -- "*.lua"`
still gets normal Git glob-pathspec semantics, deliberately — CurrantGit only
guards pathspecs it assembles on the user's behalf from a semantic item.

## Consequences

- Stage, unstage, discard, and item-diff are safe against filenames
  containing `*`, `?`, or `[`.
- `git blame` remains correct for such filenames without needing (or
  tolerating) the same guard.
- `:Git`'s escape-hatch philosophy — arbitrary Git arguments behave like
  arbitrary Git arguments — is preserved for anything the user typed
  directly.

## Revisit if

Git ever changes `:(literal)` semantics, or a future action starts building
a pathspec from something other than a single already-known-literal path
(e.g. a user-editable glob field), which would need its own explicit design
rather than blanket literal-guarding.
