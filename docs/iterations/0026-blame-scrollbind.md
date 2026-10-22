# Iteration: fugitive-style blame annotations

## Outcome

Blame is now an annotation column to the left of the source (fugitive's
placement), with one row per source line and no duplicated source text. It
is bound to the source window with `scrollbind` + `cursorbind`. While bound,
the source gets `nowrap nofoldenable` and its original options are restored
on close. Commit runs are grouped: the first row names the commit
(hash/author/date) and the rest show a `│` guide in a per-commit colour. The
hue comes from the hash and the lightness is fixed per `background`, since
raw hash colours are often unreadable.

Also fixed:

- a no-op `CursorMoved` handler that set the blame window's own cursor;
- `E95` when re-blaming the same file;
- blaming from the blame window `:edit`ing the file into the annotation
  window.

## Evidence

- Test-first: `test_blame_scrollbind` failed first on placement (blame
  opened on the right).
- Automated: row count == source lines, no source text, run grouping,
  per-row commit highlight, both windows bound, source nowrap/nofold,
  cursor sync both directions on jumps, option restoration on `gq`,
  re-blame replacing rather than stacking.
- Harness limit (verified in isolation): `nvim_feedkeys(..., "x")` runs
  outside the top-level command loop, and there Vim skips some scrollbind
  propagation that real typing gets (`50Gzt` left the bound window at the
  wrong topline even with plain buffers and no CurrantGit code). The test
  asserts on jumps, which sync on both paths.
- Manual: per-commit colours against a real colorscheme, and scroll feel,
  are still for human review.

## Drift check

Read-only: `git blame --line-porcelain` is still the only command run. The
parser only gained `author-time`.
