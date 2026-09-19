# Iteration: semantic log surface

## Outcome

`:Git log` opens a read-only native buffer containing the latest 50 commits.
Counts, revision ranges, selected filters, and root-relative pathspecs are
supported. Output-changing or unknown options retain the unrestricted command
surface. Native search and yank work against real text. `<CR>` opens the
selected commit through the existing commit view; Ctrl-O and Ctrl-Shift-I
preserve view navigation. `r` refreshes the original query and repository,
reusing the log buffer and following the selected commit by stable identity.

## Semantic seam and integrity

`currantgit.log` builds a controlled Git argv, parses NUL-delimited records,
and projects commit items into rows. Items retain full commit IDs, parent IDs,
author name/email, ISO author date, subject, repository, and open/show
capabilities. Their identity is `commit:<full-object-id>`. Rendering sanitizes
control characters without changing the metadata used by actions.

The shared executor runs all plugin Git commands. Log refresh and commit
opening keep the originating repository even after cwd changes. Failed or
malformed responses preserve the previous projection. Superseded log requests
and responses arriving after the user leaves their window/buffer are ignored.
Log interactions are read-only; no repository mutation action applies to a
commit row. Discovery, WhichKey data, and contextual help share the registry.

## Evidence

- `luac -p` passes for the changed Lua modules and tests.
- `scripts/test` passes contract validation and the clean headless fixture.
- The new log fixture presses actual buffer mappings with remapping enabled:
  Enter, refresh, help, back, and forward. It covers semantic metadata,
  read-only options, native search/yank, discovery on rows and headers, empty
  results, count/range/path selection, failed queries, custom-format fallback,
  repeated refresh, cwd changes, and selection retention after a new commit.
  Controlled responses also cover superseded queries and leaving the buffer
  before a log request completes.
- Before/after HEAD, status, worktree diff, and staged diff comparisons confirm
  that log browsing does not change the fixture repository.
- Parser assertions cover Unicode/control characters, parent lists, empty
  fields, SHA-256 IDs, and malformed/truncated records.
- `git diff --check` passes. The harness now exits with a failure status on a
  Lua assertion instead of leaving headless Neovim running.

## Boundaries

No manual visual smoke test was performed. There is no pagination, graph
layout, revision editing, or independent multi-log layout. Plain log on an
unborn HEAD reports Git's error. The existing whitespace-only command parser
still requires the Lua argv API for arguments containing spaces. All log
queries share one reusable buffer. Broader shared-surface navigation and
concurrent-request lifecycle behavior remain outside this slice.
