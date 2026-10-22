# Iteration: language-aware diff highlighting

## Outcome

`lua/currantgit/diff_syntax.lua` highlights diff text as the changed file's
language on every diff projection: the diff surface, inline status `=`
diffs, and the commit view. Each hunk is split into old (context + removed)
and new (context + added) snippets, and each snippet is parsed with the
file's treesitter parser (injections included). Captures are projected back
onto diff rows one column past the prefix, and context rows take the new
side's highlights. Add/delete rows get `line_hl_group` backgrounds below
treesitter priority, so token colours sit on top. Hunk/file headers get
their own groups, which also gives the commit view (previously plain text)
diff colouring. Files without a parser keep the backgrounds only. Regions
over 5000 lines skip treesitter.

The diff surface sets `syntax=OFF` (filetype stays `diff`) so the regex
syntax does not paint whole lines over the tokens.

## Evidence

- Test-first: `test_diff_syntax_highlighting` failed first (no add
  background on the diff surface).
- Automated, on all three surfaces with a Lua fixture: `local` is
  `@keyword.lua` at columns 1-6 (prefix-offset), the string literal is
  `@string.lua`, removed rows are highlighted from the old side, context rows
  have token colours but no add/delete background, and a `.txt` file (no
  parser) still gets the add background.
- Manual: readability of DiffAdd/DiffDelete backgrounds under token colours
  depends on the colorscheme and is still for human review.

## Drift check

Projection-only: no new Git commands. `diff.parse` gained one export
(`unquote_path`), and hunk identity and patches are unchanged.
