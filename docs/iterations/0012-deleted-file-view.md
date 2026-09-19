# Iteration: deleted-file historical view

## Outcome

Opening a deleted status item now shows its last available Git content in a
stable `currantgit://deleted/...` read-only buffer. The view keeps ordinary
Neovim buffer behavior and participates in CurrantGit view history.

## Item/action seam

The deleted item remains the authoritative domain object. Its status columns
select the index or `HEAD` revision, while the renderer presents the content
without inventing a filesystem path that no longer exists.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` creates and deletes a fixture file, opens it with
  the mapped `<CR>` action, checks historical content, and asserts read-only
  behavior.
- Unverified: deleted-file split and revision comparison affordances belong to
  later diff slices.

## Drift check

Deleted files are not treated as missing actions or empty buffers. The view is
explicitly historical and read-only, while `d` remains the change-oriented
diff surface.
