# 0011: Diff-parse unquotes and un-tab-suffixes header paths before use

## Context

Audit continuation items 4 and 5 asked whether unusual-but-valid filenames
(unicode, embedded spaces, leading dash) work end-to-end, and whether
`open_diff_args`'s single-pathspec fallback extraction is ever actually
reached. Both were verified together with a real fixture (`café.txt`,
`file with spaces.txt`, `-dashfile.txt`) driven through the actual `d`
(diff), `s`/`u` (stage/unstage), `b` (blame), and `X` (discard) mappings.

A real bug was found and reproduced: for `café.txt`, `git diff` C-quotes and
octal-escapes the header under the default `core.quotePath=true` (any byte
above 0x80 counts as "unusual"):

```
diff --git "a/caf\303\251.txt" "b/caf\303\251.txt"
--- "a/caf\303\251.txt"
+++ "b/caf\303\251.txt"
```

`diff.lua`'s header-path regex, `header:match("^%+%+%+ b/(.+)")`, does not
match a quoted `+++ "b/...".` line at all (there's a `"` right after the
space, not `b/`). With no match, `hunk.path` fell back to `options.path` —
which, reached through the real `d` mapping (`open_diff` in `init.lua`), is
the *raw constructed pathspec* `":(literal)café.txt"`, not the real
filename, because `open_diff_args`'s fallback extraction just grabs
`args[index + 1]` after `--` verbatim. `hunk.path` ended up literally
`":(literal)café.txt"`.

A second, independent quirk was found for `file with spaces.txt`: Git
appends exactly one literal trailing tab character after a header path that
contains an embedded space (a disambiguation convention, unrelated to
quoting) — `+++ b/file with spaces.txt\t`. Without stripping it, `hunk.path`
would have been `"file with spaces.txt\t"` (indistinguishable from the real
file by `==` in any consumer that doesn't know to strip it).

Leading-dash filenames (`-dashfile.txt`) triggered neither mechanism and
worked correctly already, since `:(literal)` pathspec guarding (decision
0002) already protects against a leading dash being misread as a flag.

## Decision

`diff.lua` now has an `unquote_diff_path` helper applied to every
`+++`-derived header path before the `^b/(.+)` prefix match:

1. Strip exactly one trailing tab, if present (the embedded-space
   convention).
2. If the (tab-stripped) text is wrapped in double quotes, unescape it:
   `\ooo` three-digit octal sequences to raw bytes, then `\t`, `\n`, `\"`,
   `\\` to their literal characters.

Both are independent, real Git behaviors (verified against `git help
config`'s `core.quotePath` documentation and empirically for the tab
suffix), and can combine — the order above (tab-strip, then unquote) handles
that correctly since the tab suffix is appended outside the quotes.

Additionally, `open_diff_args`'s fallback `path` (used only when a hunk has
no preceding `diff --git` header at all — practically unreachable for real
`git diff` output, but defended anyway) now strips a leading `:(literal)`
before being passed to `diff.parse`, so it can never leak CurrantGit's own
pathspec-magic prefix into `hunk.path` even in that dead-code path.

This is not a full shell/C-string unescaper — it handles exactly the escape
forms `core.quotePath` documents, matching the scope of the existing `-z`
status-parsing fix (decision 0004) rather than reimplementing general C
string literal parsing.

**Amendment (2026-09-20, found in PR #18 code review):** the first version
of this fix only special-cased `\t`, `\n`, `\"`, `\\` in the named-escape
table — exactly the escapes that version's own test fixtures happened to
exercise, not the complete set Git actually emits. An independent reviewer
reproduced a real corruption against a fixture combining a leading dash, a
UTF-8 byte, and a literal carriage return: Git quotes CR as the named escape
`\r`, and the original fallback for any unrecognized single-char escape
silently dropped the backslash and returned the bare letter — decoding `\r`
to the literal letter `r` instead of a CR byte. Verified empirically against
real Git that the complete named single-char escape set is `\a` (bell),
`\b` (backspace), `\f` (form feed), `\n`, `\r`, `\t`, `\v` (vertical tab),
plus `\"` and `\\` — the full C string-literal control-character set, not
an arbitrary subset. The named-escape table now covers all of them; a
control byte with no named escape still correctly falls back to the
existing 3-digit octal decoding. See
[`gotchas.md`](../gotchas.md) for the standing note this produced.

Regression coverage: `tests/safety.lua`, `test_unusual_paths_end_to_end`
(diff, stage, unstage, blame, and discard against all three filenames,
asserting `hunk.path` is exactly the real filename for the quoted and
tab-suffixed cases), and `test_diff_unquote_full_control_escape_set` (added
for the amendment: the reviewer's exact leading-dash/unicode/CR repro,
fed through `diff.parse` from real captured Git output).

## Consequences

- `hunk.path` is now correct for unicode, embedded-space, and leading-dash
  filenames alike. This matters even though no *current* production code
  path branches on `hunk.path` for a live action (stage/unstage use
  `hunk.patch` verbatim) — `hunk.path` is part of a hunk's public identity
  per `AGENTS.md` rule 6, and a future feature (multi-file hunk grouping, a
  "open file for this hunk" action) would otherwise inherit a silently wrong
  value for any repository with a non-ASCII or space-containing filename.
- `open_diff_args`'s multi-pathspec fallback-extraction gap (continuation
  item 5) is now understood as practically unreachable for real `git diff`
  output (it only matters if a hunk appears before any `diff --git` header
  line at all, which standard `git diff` never emits) — not fixed
  structurally, but no longer a live risk given the header-path extraction
  above is what actually determines `hunk.path` in every real case,
  including multi-pathspec diffs (each file's own header supplies its own
  real path independent of which pathspec was passed on the command line).

## Revisit if

A future diff-related feature reads `hunk.path` from a diff that somehow
lacks a `diff --git` header for its first hunk (e.g. a hand-constructed or
`--no-color --output-indicator`-mangled input) — re-verify the fallback path
extraction's multi-pathspec ambiguity (item 5) actually matters at that
point, rather than assuming this record's "practically unreachable"
assessment still holds for the new input shape.
