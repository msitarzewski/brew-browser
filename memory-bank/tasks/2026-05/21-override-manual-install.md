# 260531_override-manual-install

## Objective
Detect manually installed macOS `.app` bundles to flag Casks as "Installed by User" instead of "Not installed," providing a Destructive Confirm dialog and allowing a forced install without bypassing Homebrew's own conflict resolution.

## Outcome
- ✅ Tests: 586 passing
- ✅ Linter/Typecheck: Clean (svelte-check found 0 errors, 3 warnings)
- ✅ Security: Strictly adheres to security invariants in `security.md`. All filesystem alterations or package prefix overrides are delegated to Homebrew's own `--force` command pipeline rather than direct Rust `std::fs` operations.
- ✅ Review: PR review feedback implemented and successfully pushed.

## Files Modified
- `src-tauri/src/commands/actions.rs` - Removed manual `std::fs::remove_file` sweep block in `brew_install` and cleaned up blank lines.

## Patterns Applied
- Standard command flow where state changes and package operations are delegated safely through the `run_brew_streaming` mechanism with the appropriate `--force` flag configuration.
