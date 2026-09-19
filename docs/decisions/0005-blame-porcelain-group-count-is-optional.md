# 0005: `git blame --line-porcelain` parsing does not require the group-count field

## Context

`blame.parse`'s header regex was `"^([0-9a-f]+) (%d+) (%d+) %d+"` — it
required a trailing fourth number on every header line. Real
`--line-porcelain` output (captured directly from Git, not assumed) only
emits that fourth field — the size of the contiguous same-commit line
group — on the *first* line of such a group; every later line in the group
has only three fields.

Because the regex required all four, it failed to match every line after
the first in a same-commit run. The match failure left `commit` (and
therefore `current`) `nil`, which silently dropped that entire line's
author/summary/text record from the parser's output — not just a display
glitch, but a wrong `row.line` mapping for the blame↔source CursorMoved sync
on every subsequent line.

This was verified against real captured output from a 5-line, single-commit
fixture: before the fix, 4 of 5 lines were silently dropped.

## Decision

The header regex drops the mandatory trailing group-size field:
`"^([0-9a-f]+) (%d+) (%d+)")`. The field was already discarded unused, so
nothing downstream depended on capturing it.

## Consequences

- Every line of a same-commit contiguous run is now parsed, not just the
  first.
- No new false-positive risk: no other `--line-porcelain` line kind (author,
  author-mail, committer\*, summary, boundary, filename, previous,
  tab-prefixed content) can match `^[hex]+ digit+ digit+`, verified by
  tracing each prefix against the pattern.

## Revisit if

Git changes the `--line-porcelain` header contract (this is a long-stable,
documented format, so unlikely) or a future feature needs the group-size
field, in which case it should be captured as an *optional* trailing group,
not a required one.
