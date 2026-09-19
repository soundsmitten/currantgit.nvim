# Iteration: blame companion

## Outcome

Status items now expose `b` for a buffer-first blame companion. CurrantGit
keeps the source buffer beside a read-only attribution projection, maps blame
rows back to source lines, and provides `gq` close-and-return behavior.

## Item/action seam

Blame rows are domain objects carrying commit, author, source line, summary,
and source text. The projection is fed by Git's line-porcelain output and does
not rewrite the authoritative source buffer.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` opens blame through the mapped action, checks the
  attribution buffer and companion split, and closes it with `gq`.
- Unverified: commit opening, reblame, parent navigation, and column resizing
  are later blame slices.

## Drift check

The first blame slice preserves source-buffer authority and ordinary window
navigation. It does not turn blame into a dashboard or duplicate source text
as an editable buffer.
