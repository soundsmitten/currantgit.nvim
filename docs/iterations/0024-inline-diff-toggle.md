# Iteration: inline diff toggle (`=`)

## Outcome

Implements docs/issues/0004. On a staged or unstaged status row, `=` toggles
that file's diff inline beneath the row (index-vs-HEAD for staged,
worktree-vs-index for unstaged), reusing the shared diff parser and hunk
model. A file with both staged and unstaged changes renders as two rows and
each toggles independently, using its own row's comparison. `=` on a section
heading is unchanged: it toggles that section's native fold. Untracked and
conflict items do not offer `=` -- they have no single well-defined
comparison.

Also fixes, along the way: two follow-on fugitive-parity changes to `:Git`
(focus an already-open surface instead of duplicating it in the current
window, and honor window-opening command modifiers like `:vertical Git`),
and drops the "Changes (0)" heading and "clean" placeholder on a clean
repository in favor of fugitive's own approach (say nothing when there's
nothing to say).

## Item/action seam

`parse_status` (raw `git status` parsing) is now separate from
`render_status_body` (rendering items + any expanded diffs into buffer
lines/folds/highlights), so toggling one item's inline diff re-renders from
the last real `git status` result instead of re-running Git. Inline diff
content is fetched on demand via a single scoped `git diff [--cached] --
:(literal)path` and offset-merged into the status body's own fold/line-item
tables; hunk fold levels are shifted by the status buffer's existing
section/item nesting depth (verified empirically against Neovim's foldexpr
engine, not assumed) so `za`/`zM`/`zR` compose correctly through both
layers. Two new actions (`item.diff_toggle`, `section.toggle_fold`) share
the `=` key, resolved per item kind through the same `which_key()`
projection the discovery bar already uses.

## Evidence

- Test-first: `tests/safety.lua`'s `test_inline_diff_toggle` failed first
  (mapping not registered) against the unfixed tree.
- Automated: covers per-section comparison resolution (including a
  split staged+unstaged file using each row's own section), independent
  expansion of two files at once, untracked items never offering `=`,
  section-heading fold toggling continuing to work, expansion surviving a
  refresh for a still-existing change and being dropped for a vanished one,
  and that none of it mutates the index or worktree.
- A real bug surfaced during this pass and is fixed here too: composing the
  `(section, path)` expansion key with a literal `\0` byte in a Lua
  *pattern* (not the string being matched) silently truncated the pattern in
  LuaJIT/Lua 5.1 -- `%z` is the correct escape. See docs/gotchas.md.
- Manual: the feel of expanding/collapsing multiple files at once, and
  fold-nesting readability with a colorscheme, remain for human review.

## Drift check

Read-only: every new code path only runs `git diff`, never a mutating
command. Git execution, hunk stage/unstage semantics, and the action
registry contract for every other key are unchanged.
