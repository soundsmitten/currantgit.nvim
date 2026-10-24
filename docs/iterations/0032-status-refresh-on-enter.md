# Iteration: status refreshes itself, like fugitive

## Outcome

Status no longer goes stale when you change things somewhere else. Resolving
a conflict, `:w`, then `gq` back used to show the old `0/2` count until `r`.

Following fugitive (`fugitive#DidChange` and `s:ReloadWinStatus` in
autoload/fugitive.vim): `BufWritePost` of a file inside the status
repository marks that root changed, and `FocusGained`, `ShellCmdPost` and
`ShellFilterPost` mark every root changed. `BufEnter` and `TabEnter`, plus the
change events themselves, refresh the current status buffer when it is stale,
using the same path as `r`. The status buffer records the change counter its
`git status` request started at, so a write made during that request still
leaves it stale, and an in-flight request counts as fresh so entering twice
doesn't start a second one. The refresh is skipped outside normal mode, so a
focus change never drops a visual selection.

## Evidence

- Test-first, e2e: the resolver case, `:edit` + `:w` + `:buffer #`, and
  `FocusGained` after an outside `git add` failed against the unfixed code
  (timed out waiting for the new rows) and pass with the fix.
- Guards: entering an unchanged status (buffer switch and tab switch) runs no
  `git status`, counted from the child's command ledger. A focus change
  mid-selection keeps visual mode and runs nothing; removing the mode check
  makes that scenario fail.
- Not covered: a status buffer visible in a window other than the current
  one. Like fugitive's write path, it refreshes when entered, not in place.
