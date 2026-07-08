import Foundation

/// In-app recovery for the two brew failures users hit most and previously
/// could only fix from Terminal (issues #13/#102, #100). The native mirror of
/// the Tauri `src/lib/util/recovery.ts` (parity charter: same classification,
/// same choices, same flags).
///
/// `classify` is a PURE function of a failed `ActivityJob`: it parses the brew
/// command + stderr to decide whether a one-click retry with a different flag
/// would succeed, and which choices to offer. `ActivityView` renders the
/// resulting buttons on the failure card; `AppModel.runRecovery` re-runs the
/// command with the chosen flag.
enum BrewRecovery {
    enum Action: Sendable { case install, uninstall }
    enum Choice: String, Sendable { case adopt, overwrite, forceRemove }

    /// One retry button.
    struct ChoiceSpec: Identifiable, Sendable {
        let choice: Choice
        let label: String
        /// Danger styling (overwrite/force) vs the safe, recommended adopt.
        let isDanger: Bool
        let hint: String
        var id: String { choice.rawValue }
    }

    struct Option: Sendable {
        let action: Action
        let name: String
        let kind: InstalledPackage.Kind
        /// Plain-language headline of what went wrong.
        let reason: String
        /// Retry choices, in display order (safest first).
        let choices: [ChoiceSpec]
    }

    /// Parse `[brew] <action> [--cask|--formula] <name> [flags…]` from a job's
    /// display command. nil when it isn't a recognizable install/uninstall.
    static func parse(command: String) -> (Action, String, InstalledPackage.Kind)? {
        var toks = command.split(whereSeparator: { $0 == " " }).map(String.init)
        if toks.first == "brew" { toks.removeFirst() }
        guard let verb = toks.first else { return nil }
        let action: Action
        switch verb {
        case "install": action = .install
        case "uninstall": action = .uninstall
        default: return nil
        }
        let kind: InstalledPackage.Kind = toks.contains("--cask") ? .cask : .formula
        guard let name = toks.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
        return (action, name, kind)
    }

    /// Decide whether a failed job can be retried in-app, and how. Pure.
    /// Returns nil for success, cancel, no-exit-code (our spawn failure), or an
    /// unrecognized error.
    static func classify(_ job: ActivityJob) -> Option? {
        guard job.status == .failed, job.exitCode != nil else { return nil }
        guard let (action, name, kind) = parse(command: job.command) else { return nil }
        let text = job.lines.map(\.text).joined(separator: "\n").lowercased()

        if action == .install, alreadyExists(text) {
            var choices: [ChoiceSpec] = []
            // --adopt only exists for casks; it's the safe, recommended fix.
            if kind == .cask {
                choices.append(ChoiceSpec(
                    choice: .adopt, label: L10n.string("Adopt existing"), isDanger: false,
                    hint: L10n.isRussian ? "Передать Homebrew уже установленную копию на этом Mac, не перемещая её." : "Let Homebrew manage the copy already on your Mac (keeps it in place)."))
            }
            choices.append(ChoiceSpec(
                choice: .overwrite, label: L10n.isRussian ? "Заменить" : "Overwrite", isDanger: true,
                hint: L10n.string("Replace the existing copy with a fresh Homebrew install.")))
            return Option(action: action, name: name, kind: kind,
                          reason: L10n.isRussian ? "\(name) уже установлен вне Homebrew." : "\(name) is already installed outside Homebrew.",
                          choices: choices)
        }

        if action == .uninstall, requiredBy(text) {
            return Option(action: action, name: name, kind: kind,
                          reason: L10n.isRussian ? "\(name) всё ещё требуется другому установленному пакету." : "\(name) is still required by another installed package.",
                          choices: [ChoiceSpec(
                            choice: .forceRemove, label: L10n.string("Force remove"), isDanger: true,
                            hint: L10n.string("Remove it anyway, ignoring packages that depend on it."))])
        }

        return nil
    }

    // brew's "already installed outside Homebrew" message (cask "App" + the
    // rarer formula/binary variants), across brew versions.
    private static func alreadyExists(_ lowered: String) -> Bool {
        lowered.contains("already an app at")
            || lowered.contains("it seems there is already a")
    }

    // brew's dependency-protection refusal on uninstall.
    private static func requiredBy(_ lowered: String) -> Bool {
        lowered.contains("refusing to uninstall") || lowered.contains("required by")
    }
}
