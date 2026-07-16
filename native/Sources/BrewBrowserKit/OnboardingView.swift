import SwiftUI
import AppKit

/// Full-window onboarding pane shown when no Homebrew install can be found
/// (`AppModel.brewMissing` — ContentView swaps the whole root for this view).
/// Walks the user through the official install: Command Line Tools first when
/// they're missing, then the Homebrew one-liner, with a Copy button and an
/// "Open Terminal" shortcut. A footer spinner notes that the app re-checks on
/// its own (`AppModel.pollForBrew`, every 2s) and proceeds automatically.
///
/// Stock SwiftUI only — standard text styles, `GroupBox`, `ProgressView`,
/// plain buttons. No window/chrome/material overrides.
struct OnboardingView: View {
    @Bindable var model: AppModel

    /// The official Homebrew install one-liner (brew.sh), surfaced VERBATIM.
    /// A fixed constant — never built up or interpolated.
    static let installCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    /// The Apple command that installs the Command Line Tools. Fixed constant,
    /// shown (and copied) verbatim.
    static let cltCommand = "xcode-select --install"

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Headline — mirrors the ContentUnavailableView layout the app's
            // other full-pane states use (icon, title, secondary description),
            // hand-rolled here because this pane also carries steps + actions.
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(L10n.string("Homebrew isn't installed"))
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(L10n.string("brew-browser is a window onto Homebrew — install it and the app takes it from there."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                // Step: Command Line Tools, only when the probe says missing —
                // the Homebrew installer needs them, so they come first.
                if !model.cltInstalled {
                    step(number: 1, title: L10n.string("Install the Xcode Command Line Tools"),
                         detail: L10n.string("The Homebrew installer needs them. Run this in Terminal and follow the prompt:"),
                         command: Self.cltCommand)
                }

                step(number: model.cltInstalled ? 1 : 2, title: L10n.string("Install Homebrew"),
                     detail: L10n.string("Paste the official install command (from brew.sh) into Terminal:"),
                     command: Self.installCommand)

                HStack {
                    Spacer()
                    Button {
                        openTerminal()
                    } label: {
                        Label(L10n.string("Open Terminal"), systemImage: "terminal")
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: 560)

            // Quiet auto-advance note — the poll flips `brewMissing` the moment
            // brew resolves and the normal UI takes over by itself.
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Waiting for Homebrew… the app continues automatically once it's installed."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Re-check brew + the CLT every 2s while this pane is up. SwiftUI
        // cancels the task with the view, so nothing polls after onboarding.
        .task { await model.pollForBrew() }
    }

    /// One numbered step: title, secondary detail, and the command in a
    /// selectable monospaced row with a Copy button. Stock `GroupBox` chrome.
    private func step(number: Int, title: String, detail: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(number). \(title)")
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            GroupBox {
                HStack(spacing: 12) {
                    Text(command)
                        .font(.callout)
                        .monospaced()
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        copyToPasteboard(command)
                    } label: {
                        Label(L10n.string("Copy"), systemImage: "doc.on.doc")
                    }
                    .help(L10n.string("Copy the command to the clipboard"))
                }
                .padding(4)
            }
        }
    }

    /// Copy a fixed command string to the general pasteboard (same NSPasteboard
    /// usage as the GitHub device-flow code copy in AppModel).
    private func copyToPasteboard(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Open Terminal.app via its FIXED bundle identifier — a constant Launch
    /// Services lookup with zero string interpolation (no AppleScript, no shell).
    private func openTerminal() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

#if DEBUG
#Preview("Onboarding — no CLT") {
    OnboardingView(model: AppModel())
        .frame(width: 820, height: 640)
}
#endif
