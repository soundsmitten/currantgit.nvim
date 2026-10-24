# Issue 0010: Conflict resolver with semantic conflict items

## Status

Proposed. Touches index/worktree state: follows the Git safety doctrine and
the two-phase implementation/adversarial-validation workflow in
`docs/development.md`.

## Goal

Make merge/rebase/cherry-pick conflict resolution a first-class CurrantGit
surface: each conflict is a semantic item with stable identity, resolved by
contextual actions in a three-pane, native-diff-mode layout. This is
deliberately beyond fugitive's `:Gdiffsplit!` + `:diffget //2` workflow:
show *what each side changed relative to base*, not just two blobs.

## Item model

- `conflict-file:<path>` — a file in the Conflicts status section (already
  classified via the exact unmerged code set, decisions/0007). Carries
  resolved/total counts.
- `conflict:<path>:<n>` — one conflict region. Fields: `ours`, `theirs`,
  `base` (line arrays), `result_range`, `state`
  (`unresolved`/`ours`/`theirs`/`both_ours_first`/`both_theirs_first`/
  `base`/`edited`).
- Source of truth for sides is the index stages (`:1:` base, `:2:` ours,
  `:3:` theirs) via `git show :<n>:<path>` (explicit stage form, see
  decisions/0012), not re-parsing markers the user may already have edited.
  Regions in the worktree file are located from markers; verify the marker
  styles (`merge`, `diff3`, `zdiff3`) against `git help merge-file` /
  `merge.conflictStyle` docs before parsing.

## Surface

```
┌─ ours (HEAD) ─┬─ result (real file) ─┬─ theirs ──────┐
│  read-only    │  editable            │  read-only    │
└───────────────┴──────────────────────┴───────────────┘
           base: toggled overlay/split, not a 4th pane
```

- Native `diff` mode across panes so `]c`, `[c`, `do`, `dp` keep working.
- Per-conflict word-level highlights of each side's change vs base.
- Virtual text in the result pane marks which side a chunk came from.
- Status Conflicts section shows `resolved/total` per file; `]x`/`[x`
  jump between conflict items across files.
- Header shows operation context: "Rebasing 3/7: <sha> <subject>".

## Actions (proposed IDs)

| id | key | behavior |
| --- | --- | --- |
| `conflict.open` | `<CR>` | open the three-pane resolver for a file |
| `conflict.take_ours` | `o` | replace region with ours |
| `conflict.take_theirs` | `t` | replace region with theirs |
| `conflict.take_both` | `b` / `B` | both, ours-first / theirs-first |
| `conflict.take_base` | `0` | replace region with base |
| `conflict.restore` | `R` | restore the file's original conflict state (`git checkout -m -- :(literal)<path>`, after confirmation) |
| `conflict-file.mark_resolved` | `s` | `git add` — only offered when no unresolved region remains |
| `operation.continue` / `.skip` / `.abort` | | rebase/merge control, abort confirmed |

Region choices edit the result buffer only (undoable with `u`); nothing
touches the index until `mark_resolved`.

## Verified Git behavior (git 2.50.1, fixture repo)

Checked before slice 3 relies on them:

- `AA` (add/add) has stages 2 and 3 only; `git show :1:<path>` fails with
  "is in the index, but not at stage 1". Base must be optional everywhere.
- Modify/delete shows `UD` (deleted by them) with stages 1 and 2 only. The
  `DU` mirror should lack stage 2; not yet run, so cover it in the fixture.
  A missing side gets no pane content and no take action, not an empty blob.
- `git checkout -m -- :(literal)<path>` recreates stages 1-3 and the marker
  file even after the file was `git add`ed (resolve-undo), and overwrites the
  worktree file. `conflict.restore` therefore always confirms.
- Recreated markers are labelled `ours`/`theirs`/`base`, not the original
  `HEAD`/branch labels, so the marker parser must not depend on labels.
- `git checkout --conflict=zdiff3 -- <path>` re-emits a file in a given
  style; fixtures can use it to cover `merge`/`diff3`/`zdiff3` from one
  conflict.

## Slices

1. Read-only: parse conflicts into items from index stages + worktree
   markers, show three-pane view, counts in status. No mutation.
2. Region actions on the result buffer (buffer edits only).
3. `mark_resolved`, `restore`, operation continue/skip/abort — Git
   mutations; adversarial validation pass required.
4. Stretch: suggested auto-merge of non-overlapping edits within one
   region (suggest, never apply silently); `git rerere` surfacing.

## Validation

- Git fixtures: merge conflict, rebase conflict, add/add (`AA`),
  delete/modify (`UD`/`DU` — no stage 2 or 3), binary conflict, conflict in
  an unusual path (unicode/space/leading dash), `diff3`/`zdiff3` styles.
- Headless interaction tests for every mapping (AGENTS.md rule 13).
- Test-first; mutation tests assert on `git ls-files -u` / index state, not
  buffer text.

## Boundaries

- No libgit2, no custom merge algorithm in slice 1–3.
- `:Git mergetool` / `:Git merge` stay available via the `:Git` escape hatch.
- Never stage a file with remaining markers; never discard user edits in the
  result buffer without confirmation.
