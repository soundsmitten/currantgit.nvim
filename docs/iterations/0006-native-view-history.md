# Iteration: native view history

## Outcome

CurrantGit-managed surfaces now expose regular back and forward navigation:
`Ctrl-O` returns to the previous view and `Ctrl-Shift-I` moves forward again.
The view entry preserves buffer identity, cursor position, and window view.

## Evidence

- Automated: Lua syntax checks pass.
- Automated: `scripts/test` covers status → file → back → forward.
- Unverified: blame, diff split, tab, and preview transitions.

## Drift check

The navigation layer is buffer-local and only attaches to CurrantGit-managed
views. It does not globally remap Neovim’s navigation keys.
