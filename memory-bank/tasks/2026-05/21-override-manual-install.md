# 260531_override-manual-install

## Objective
Detect manually installed macOS `.app` bundles to flag Casks as "Installed by User" instead of "Not installed," providing a Destructive Confirm dialog and allowing a forced install without bypassing Homebrew's own conflict resolution. 
Additionally, detect if manual app installations originate from the **Mac App Store** to warn users about macOS system/quarantine permission locks and block the force-install flow with clear resolution guidance.

## Outcome
- ✅ Tests: 586 passing
- ✅ Linter/Typecheck: Clean (svelte-check found 0 errors, 3 warnings)
- ✅ Security: Strictly adheres to security invariants in `security.md`. All filesystem alterations or package prefix overrides are delegated to Homebrew's own `--force` command pipeline rather than direct Rust `std::fs` operations.
- ✅ Review: PR review feedback implemented and successfully pushed.
- ✅ Mac App Store Integration: Automatically checks for `Contents/_MASReceipt/receipt` inside app bundles. If a MAS app is matched, the UI blocks force-install overrides (which are guaranteed to fail due to macOS permissions) and guides the user to delete the App Store bundle manually first.

## Files Modified
- `src-tauri/src/commands/actions.rs` - Removed manual `std::fs::remove_file` sweep block in `brew_install` and cleaned up blank lines.
- `src-tauri/src/types.rs` - Added `is_mas: bool` to the `PackageDetail` struct.
- `src-tauri/src/brew/parse.rs` - Defined macOS `check_app_is_mas_macos` file receipt-checker helper, and populated `is_mas` in `RawFormula` and `RawCask` `to_detail` structures.
- `src/lib/types.ts` - Extended `PackageDetail` frontend interface with `isMas: boolean`.
- `src/lib/components/DestructiveConfirm.svelte` - Integrated `confirmDisabled?: boolean` property to allow Svelte UI to disable dangerous actions.
- `src/lib/components/PackageDetail.svelte` - Configured `DestructiveConfirm` dialog with specific warning banner messaging, custom locked titles, and blocked confirm buttons when `detail.isMas` is true.

## Patterns Applied
- Standard command flow where state changes and package operations are delegated safely through the `run_brew_streaming` mechanism with the appropriate `--force` flag configuration.
- Discriminated front-end status adaptivity based on data-driven checks on the backend (e.g. MAS receipt verification).
