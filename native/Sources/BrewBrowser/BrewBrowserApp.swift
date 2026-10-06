import SwiftUI
import AppKit
import BrewBrowserKit

@main
struct BrewBrowserApp: App {
    /// When launched as a bare SPM binary (Xcode ⌘R uses the DerivedData
    /// executable, which has no Info.plist), macOS treats the process as a
    /// background/accessory app — the window never comes forward and there's no
    /// Dock icon or menu bar. Forcing `.regular` + activating makes it a normal
    /// foreground app. Harmless when run from the real `.app` bundle (already
    /// `.regular`); this just makes Xcode Run + the debugger usable directly.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The shared app model, owned at the scene root so the scene-level
    /// `.commands` keyboard shortcuts and `ContentView`'s views act on one
    /// instance. (SwiftUI's stock pattern for shared scene + command state.)
    @State private var model = AppModel()

    /// The Sparkle updater, owned at the scene root for the app's lifetime so the
    /// "Check for Updates…" menu item, the Settings → Updates tab, and the
    /// titlebar "update available" pill all read one instance (Bundle C).
    @State private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, updater: updater)
                // Wire the shared model into the AppDelegate so incoming
                // `brewbrowser://` deep links route into THIS window (via
                // `application(_:open:)`) instead of SwiftUI's `.onOpenURL`
                // spawning a second window.
                .onAppear { appDelegate.setModel(model) }
        }
        // Don't let the WindowGroup open a new window for external events
        // (`brewbrowser://` URL opens). An empty match set keeps the initial
        // window the only one; the AppDelegate routes the URL into it.
        .handlesExternalEvents(matching: [])
        .windowStyle(.automatic)
        // Native macOS toolbar style — the unified title bar that hosts the
        // Liquid Glass toolbar buttons.
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        // Keep a coherent minimum window size (sidebar + main-pane min +
        // inspector min) while staying freely resizable. Without this, dragging
        // the inspector near the window edge can get grabbed as a window resize.
        .windowResizability(.contentMinSize)
        // Keyboard shortcuts — ⌘K palette, ⌘0–6 section nav, ⌘L drawer, ⌘R
        // refresh, ⌘⇧L theme cycle. Stock `.commands` menus; the bound model is
        // the same one ContentView renders.
        .commands {
            AppCommands(model: model, updater: updater)
        }

        // Native Settings scene — opened by ⌘, the app menu, or the toolbar
        // gear (SettingsLink in ContentView). ⌘, is provided by SwiftUI.
        Settings {
            SettingsView(model: model, updater: updater)
        }
    }
}

/// The app's keyboard-shortcut menus, ported from the Tauri global-key handler
/// (`src/routes/+page.svelte:46-128`) and the sidebar ⌘0–6 map
/// (`Sidebar.svelte:35-43`). All stock SwiftUI `Commands` — they surface in the
/// menu bar AND register the shortcuts. Async model calls are wrapped in `Task`.
struct AppCommands: Commands {
    @Bindable var model: AppModel
    /// The Sparkle updater backing the "Check for Updates…" menu item (Bundle C).
    var updater: UpdaterController

    var body: some Commands {
        // Replace the stock "About brew-browser" item with our custom About box
        // (AboutView sheet) — a richer, brand hero + credits + donate CTA that
        // mirrors the Tauri AboutModal. A "Sponsor brew-browser…" item sits below
        // so the donate CTA also lives in the app menu.
        CommandGroup(replacing: .appInfo) {
            Button("About Brew Browser") { model.aboutOpen = true }
            Button("Sponsor Brew Browser…") {
                if let url = URL(string: AboutInfo.sponsorURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        // "Check for Updates…" in its own group right after the About group
        // (Bundle F replaces .appInfo itself, so we slot in `after: .appInfo` so
        // both coexist). Disabled while a check is already in flight, per
        // Sparkle's documented SwiftUI integration. Mirrors the Tauri "Check now"
        // (`SettingsSectionUpdates.svelte`).
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        // A dedicated "Go" menu hosts the section-nav shortcuts (⌘0–6) so they
        // appear together with their key equivalents, like a stock View menu.
        CommandMenu("Go") {
            Button("Dashboard") { model.go(toSectionNumber: 0) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Library")   { model.go(toSectionNumber: 1) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Discover")  { model.go(toSectionNumber: 2) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Trending")  { model.go(toSectionNumber: 3) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Snapshots") { model.go(toSectionNumber: 4) }
                .keyboardShortcut("4", modifiers: .command)
            Button("Services")  { model.go(toSectionNumber: 5) }
                .keyboardShortcut("5", modifiers: .command)
            Button("Activity")  { model.go(toSectionNumber: 6) }
                .keyboardShortcut("6", modifiers: .command)
            Button("Bundles")   { model.go(toSectionNumber: 7) }
                .keyboardShortcut("7", modifiers: .command)

            Divider()

            // ⌘K command palette.
            Button("Command Palette…") { model.paletteOpen = true }
                .keyboardShortcut("k", modifiers: .command)
        }

        // ⌘R refresh + ⌘L drawer toggle replace the stock toolbar/sidebar
        // command group so they slot into the View menu.
        CommandGroup(after: .toolbar) {
            Button("Refresh") {
                Task { await model.refreshCurrent() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isLoading)

            Button(model.drawerOpen ? "Hide Activity Drawer" : "Show Activity Drawer") {
                model.toggleDrawer()
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Cycle Theme") { model.cycleTheme() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

/// Sponsor URL for the app menu's "Sponsor Brew Browser…" item. Matches the
/// toolbar heart + About box.
enum AboutInfo {
    static let sponsorURL = "https://github.com/sponsors/msitarzewski"
}


/// Promotes a bare/unbundled launch (Xcode ⌘R) to a normal foreground app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The scene's shared model, handed over by the `WindowGroup` on appear so
    /// deep links can drive the existing window. Weak — the `@State` in the App
    /// owns it for the process lifetime.
    private weak var model: AppModel?
    /// A deep link that arrived before the model was wired (cold launch via a
    /// `brewbrowser://` URL); replayed the moment the model is set.
    private var pendingURL: URL?

    /// Called from the `WindowGroup`'s `.onAppear`. Adopts the model and flushes
    /// any URL that landed during a cold launch.
    func setModel(_ model: AppModel) {
        self.model = model
        if let url = pendingURL {
            pendingURL = nil
            model.handleDeepLink(url)
        }
    }

    /// AppKit's URL-open entry point. Handling it here (rather than SwiftUI's
    /// `.onOpenURL`) routes `brewbrowser://` links into the current window
    /// instead of opening a new one. Before the model is wired (cold launch),
    /// the URL is stashed and replayed in `setModel`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model {
            model.handleDeepLink(url)
        } else {
            pendingURL = url
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Real Dock/⌘-Tab icon, loaded from BrewBrowserKit's bundle — works for
        // the bare binary (Xcode ⌘R) too, not just the build-app.sh .app.
        applyDockIcon()
        // Window size/position persistence (Bundle F — parity with Tauri PR #17).
        // SwiftUI's WindowGroup leans on macOS state restoration, which doesn't
        // reliably persist the frame for the SPM/bare-binary run paths (and is
        // skipped after a force-quit). Setting an NSWindow `frameAutosaveName`
        // makes AppKit save+restore the frame to UserDefaults independent of
        // state restoration, so size+position survive relaunch in every run path.
        persistWindowFrame()
    }

    /// Give the main window a `frameAutosaveName` so AppKit persists its size +
    /// position across launches. The SwiftUI window isn't attached at
    /// `applicationDidFinishLaunching`, so retry on the next run-loop turn until
    /// it exists (bounded), then set the autosave name once.
    @MainActor
    private func persistWindowFrame(attempt: Int = 0) {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else {
            // Window not created yet — try again shortly (cap the retries so a
            // truly window-less run, e.g. tests, doesn't spin).
            if attempt < 20 {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    self.persistWindowFrame(attempt: attempt + 1)
                }
            }
            return
        }
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("BrewBrowserMainWindow")
        }
    }
}
