# Iteration: safe semantic hunk actions

## Outcome

Diff hunk nodes now support first-class staging and unstaging. The action is
resolved from the semantic hunk under the cursor, not from a rendered line
number, and the diff surface is refreshed after a successful mutation.

## Safety boundary

CurrantGit passes the exact parsed patch to `git apply` over stdin. It does not
interpolate patch text into a shell command. Git remains the authority for
whether the patch applies, and a non-zero result is reported without treating
the mutation as successful. The headless fixture proves both directions on a
real temporary repository.

## Buffer behavior

Hunks remain read-only native fold roots. `s` stages the current working-tree
hunk, while `u` reverses the current staged hunk. Multiple files may be
present in one diff; item identity and path extraction keep the action scoped
to the selected hunk.

## Evidence

- Automated: contract validation and `git diff --check` pass.
- Automated: clean headless Neovim smoke coverage stages and unstages a real
  hunk through the mapped actions.
- Automated: the same smoke path verifies native hunk folding and regular
  Ctrl-O / Ctrl-Shift-I view navigation.

## Drift check

The hunk action seam is intentionally narrow: patch parsing, action dispatch,
Git execution, and projection refresh are separate. Partial staging remains a
Git operation, not a renderer-owned interpretation of repository state.
