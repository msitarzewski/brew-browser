import SwiftUI
import AppKit

/// Sets the Dock / ⌘-Tab icon at runtime from the bundled `AppIcon.icns`.
/// Needed because the bare `swift build` / Xcode ⌘R binary has no `.app`
/// Info.plist icon — only the `build-app.sh` bundle does. Loading from
/// `Bundle.module` makes the real icon show in BOTH run paths. Call once at
/// launch (from the executable's AppDelegate).
@MainActor
public func applyDockIcon() {
    guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
          let image = NSImage(contentsOf: url) else { return }
    NSApplication.shared.applicationIconImage = image
}

/// Root chrome — stock `NavigationSplitView`, no overrides. Apple renders the
/// sidebar, the unified title bar, the toolbar, and all materials. We don't
/// touch the window, tint, transparency, or title bar.
public struct ContentView: View {
    /// The shared app model. Owned by the `App` scene (BrewBrowserApp) so the
    /// scene-level `.commands` keyboard shortcuts drive the very same instance
    /// the views render. `@Bindable` here, `@State` at the owner.
    @Bindable var model: AppModel
    /// The shared Sparkle updater (Bundle C) — drives the titlebar "update
    /// available" pill below.
    var updater: UpdaterController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel, updater: UpdaterController) {
        self.model = model
        self.updater = updater
    }

    public var body: some View {
        // Missing-Homebrew gate: while no brew binary resolves, the whole
        // window is the onboarding pane. The normal chrome (and its `.task`
        // initial loads — bundled data, GitHub status, library) doesn't exist
        // until brew appears, so nothing fires brew subprocesses early. When
        // `pollForBrew` flips the flag, `mainContent` is built and those
        // `.task`s run the standard initial load sequence.
        if model.brewMissing {
            OnboardingView(model: model)
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
      VStack(spacing: 0) {
        NavigationSplitView {
            List(Section.allCases, selection: $model.selection) { section in
                Label(section.localizedTitle, systemImage: section.symbol)
                    .badge(model.badge(for: section) ?? 0)  // stock count badge; 0 hides it
                    .tag(section)
            }
            .navigationTitle("brew-browser")
            // Footer brew-health status row (Bundle F) — a colored dot + short
            // label below the section list, mirroring the Tauri sidebar footer
            // (`Sidebar.svelte:321-334`). Click re-probes the brew env. Stock
            // `.safeAreaInset` keeps it pinned below the scrolling List.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    VulnFooterRow(model: model)
                    BrewStatusRow(model: model)
                }
            }
            // The inspector belongs to the section that opened it — navigating
            // to a different section dismisses it.
            .onChange(of: model.selection) { model.closeDetailIfSectionChanged() }
            // Parse the bundled categories/enrichment JSON in the background at
            // launch so the heavy decode never blocks first paint.
            .task { await model.loadBundledData() }
            // Eagerly read GitHub status so the toolbar Octocat chip can render.
            .task { await model.loadGithubStatus() }
            // Creds are lazy — re-read status when the window becomes active
            // again (e.g. after signing in via Settings) so the chip + dashboard
            // card light up without a manual refresh.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.loadGithubStatus() } }
            }
            // Wider sidebar so section labels + count badges never crowd, and
            // there's room for the toolbar's icon+text mode without overflow.
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            detail
                // Give the main pane a firm minimum width so dragging the
                // inspector divider takes space from the content down to this
                // floor and then STOPS — instead of collapsing the pane (which
                // the window then grabs as a resize, hiding the inspector).
                // Pairs with .windowResizability(.contentMinSize) on the scene.
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(model.selection.localizedTitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        // "Update available" pill (Bundle C) — mirrors the Tauri
                        // UpdateIndicator. Shown only when Sparkle found a valid
                        // update AND Offline Mode is off (network features stay
                        // suppressed in Offline Mode). Click opens Sparkle's
                        // standard update UI.
                        if updater.updateAvailable && !AppSettings.shared.paranoidMode {
                            Button {
                                updater.checkForUpdates()
                            } label: {
                                Label(L10n.string("updates.available"), systemImage: "arrow.up.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                            .help(L10n.string("updates.available.help"))
                        }

                        Button {
                            Task { await model.refresh() }
                        } label: {
                            // Spinner replaces the arrow while refreshing so the
                            // toolbar button shows active feedback, not just a
                            // disabled grey-out.
                            Label {
                                Text(L10n.string("action.refresh"))
                            } icon: {
                                if model.isLoading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                        }
                        .disabled(model.isLoading)

                        // Donate — opens the project's GitHub Sponsors page.
                        Button {
                            if let url = URL(string: "https://github.com/sponsors/msitarzewski") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)
                        }
                        .help(L10n.string("chrome.donate.help"))

                        // GitHub connection chip — only when signed in. Green when
                        // the public_repo scope is present (star/watch/issue work),
                        // amber when the scope is incomplete. Opens Settings.
                        if model.githubSignedIn {
                            Button {
                                // Deep-link Settings to the GitHub pane.
                                UserDefaults.standard.set(SettingsTab.github.rawValue, forKey: "settings.selectedTab")
                                openSettings()
                            } label: {
                                GithubMarkIcon(size: 15)
                                    .foregroundStyle(model.githubScopeComplete ? Color.green : Color.orange)
                            }
                            .help(model.githubScopeComplete
                                ? String(format: L10n.string("github.connectedAs.format"), model.githubStatus?.username ?? "user")
                                : L10n.string("github.scopeIncomplete"))
                        }

                        // Stock SettingsLink opens the native Settings scene.
                        SettingsLink {
                            Label(L10n.string("settings.title"), systemImage: "gearshape")
                        }
                    }
                }
                // Search lives on the DETAIL column (the main content area), not
                // the split-view root — so it stays in the content toolbar and
                // doesn't drift over the inspector (and the inspector's boundary
                // divider falls cleanly at the panel edge, not through the
                // toolbar between our icons and the field).
                .searchable(text: $model.globalQuery, placement: .toolbar, prompt: Text(L10n.string("search.packages")))
                .searchSuggestions {
                    ForEach(model.suggestions) { pkg in
                        HStack(spacing: 8) {
                            PackageIcon(model: model, token: pkg.name, kind: pkg.kind, size: 16)
                            Text(pkg.name)
                        }
                        .searchCompletion(pkg.name)
                    }
                }
                .onSubmit(of: .search) {
                    if let match = model.installed.first(where: {
                        $0.name.caseInsensitiveCompare(model.globalQuery) == .orderedSame
                    }) ?? model.suggestions.first {
                        model.openInLibrary(match)
                    }
                }
                // Package detail — stock right-side inspector, on the detail column.
                .inspector(isPresented: Binding(
                    get: { model.showDetail },
                    // A drag-collapse flips this to false but KEEPS the loaded
                    // package, so re-expanding mid-gesture restores content. The
                    // ⊗ close box calls closeDetail() to actually clear the data.
                    set: { model.showDetail = $0 }
                )) {
                    // The inspector must present a STABLE size contract while the
                    // user drags the divider. Putting .inspectorColumnWidth on an
                    // always-present Group (not on the conditionally-created
                    // PackageDetailView) and letting the content fill the column
                    // stops the hosting view from re-reporting min/max mid-drag.
                    // That re-report otherwise triggers a re-entrant NSWindow
                    // constraint update during -[NSSplitView mouseDown:], which
                    // AppKit aborts (SIGABRT) — or resolves by resizing the
                    // window / hiding the inspector instead of resizing it.
                    //
                    // NOTE: stock `.inspector` dismisses itself when the divider
                    // is dragged below `min` — that's Apple's built-in collapse
                    // behavior, not removable without fighting NSSplitView. We set
                    // a generous `min` (360) so collapsing takes a deliberate hard
                    // drag rather than an accidental nudge; the in-panel close box
                    // (xmark.circle in PackageDetailView) is the intended dismiss.
                    Group {
                        if let pkg = model.detailPackage {
                            PackageDetailView(model: model, pkg: pkg)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .inspectorColumnWidth(min: 360, ideal: 400, max: 560)
                }
        }
        // Activity drawer as a true full-width bottom bar BELOW the whole split
        // view (sibling, not an inset/overlay) — so the split view + the
        // inspector's own footer live entirely above it and nothing is covered.
        ActivityDrawer(model: model)
      }
      // In-window toasts (Bundle F) — layered top-trailing over everything so
      // they're clear of the bottom Activity drawer. See Toast.swift.
      .overlay { ToastOverlay(model: model) }
      .task {
            model.loadJobs()
            model.loadVulns()
            if model.installed.isEmpty { await model.loadLibrary() }
      }
      // ⌘K command palette — stock `.sheet` overlay (BrewBrowserApp's .commands
      // flips `paletteOpen`). The catalog backs the palette's index search, so
      // make sure it's loaded the first time the palette opens.
      .sheet(isPresented: $model.paletteOpen) {
          CommandPaletteView(model: model)
      }
      // Custom About box (replaces the bare standard panel) — opened from the
      // app menu's "About brew-browser". Mirrors the Tauri AboutModal.
      .sheet(isPresented: $model.aboutOpen) {
          AboutView(model: model)
      }
      // Esc closes the open detail inspector. The palette is a `.sheet`, which
      // handles its own Esc, so by the time Esc reaches here the palette is
      // already closed and only the inspector remains. Returns `.ignored` when
      // there's nothing to close so Esc keeps its default behavior elsewhere.
      .onKeyPress(.escape) {
          model.closeTopmostOverlay() ? .handled : .ignored
      }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .dashboard:
            DashboardView(model: model)
        case .library:
            LibraryView(model: model)
        case .discover:
            DiscoverView(model: model)
        case .trending:
            TrendingView(model: model)
        case .activity:
            ActivityView(model: model)
        case .snapshots:
            SnapshotsView(model: model)
        case .services:
            ServicesView(model: model)
        }
    }
}

/// Installed packages — a stock SwiftUI `Table` (the macOS sortable
/// multi-column control: click-to-sort headers, resizable columns, native
/// selection). A segmented type filter sits in a thin bar above it. Selection
/// drives the shared package-detail inspector. No custom row chrome.
struct LibraryView: View {
    @Bindable var model: AppModel

    /// The table's selection — the package `id` (name). Mirrors the inspector's
    /// open package so the highlighted row tracks the detail panel.
    @State private var selectedID: LibraryRow.ID?

    var body: some View {
        Group {
            if model.isLoading && model.installed.isEmpty {
                ProgressView(L10n.string("Reading your Homebrew install…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = model.loadError {
                ContentUnavailableView(
                    L10n.string("Couldn't load packages"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )
            } else {
                VStack(spacing: 0) {
                    filterBar
                    if let label = model.libraryCategoryLabel {
                        categoryChip(label)
                    }
                    Divider()
                    table
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // NOTE: no `.searchable` here — Library filters off the shared toolbar
        // search field (`globalQuery`, declared on the detail column). A second
        // `.searchable` would register a duplicate toolbar search item and crash
        // AppKit on layout ("NSToolbar already contains com.apple.SwiftUI.search").
        // Keep the table highlight in sync with the inspector: if detail is
        // closed elsewhere (⊗ box), clear the row selection too.
        .onChange(of: model.showDetail) { _, shown in
            if !shown { selectedID = nil }
        }
        // Lazy first vuln scan when the user lands on (or switches to) the
        // Vulnerable filter, so the rows/count populate even without visiting
        // the Dashboard first (mirrors the Tauri store's scanIfNeeded).
        .task(id: model.libraryFilter) {
            if model.libraryFilter == .vulnerable { await model.scanVulnsIfNeeded() }
        }
    }

    // Segmented type filter with per-filter counts. Stock control, no overrides.
    // Centered in the bar — the macOS view-switcher convention (Finder/Preview).
    private var filterBar: some View {
        Picker(L10n.string("Filter"), selection: $model.libraryFilter) {
            ForEach(model.availableLibraryFilters) { f in
                Text("\(f.localizedTitle) (\(model.libraryFilterCount(f)))").tag(f)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Removable chip showing the active category filter (set by tapping a
    // slice in the Dashboard "Top categories" card). Mirrors the Tauri
    // Library chip-bar. See #58.
    private func categoryChip(_ label: String) -> some View {
        HStack(spacing: 6) {
            Button {
                model.clearLibraryCategory()
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.display(label))
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.12), in: .capsule)
            }
            .buttonStyle(.plain)
            .help(L10n.isRussian ? "Сбросить фильтр категорий" : "Clear category filter")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var table: some View {
        if model.sortedLibraryRows.isEmpty {
            if model.globalQuery.isEmpty {
                ContentUnavailableView(
                    L10n.string("No packages"),
                    systemImage: "shippingbox",
                    description: Text(L10n.isRussian
                                      ? "По фильтру «\(model.libraryFilter.localizedTitle)» ничего не найдено."
                                      : "Nothing matches the \(model.libraryFilter.rawValue.lowercased()) filter.")
                )
            } else {
                ContentUnavailableView.search(text: model.globalQuery)
            }
        } else {
            // Two fixed-column-set variants instead of a conditional
            // `TableColumn` inside one builder: wrapping a column in `if`
            // makes the underlying NSTableColumn set unstable and AppKit
            // throws an NSException mid-layout (SIGTRAP via _crashOnException).
            // The AI-gated Description column lives in its own static variant.
            if model.settings.aiFeaturesVisible {
                tableWithDescription
            } else {
                tableNoDescription
            }
        }
    }

    private var tableWithDescription: some View {
        Table(model.sortedLibraryRows, selection: $selectedID, sortOrder: $model.librarySort) {
            TableColumn(L10n.string("Name"), value: \.name) { row in
                nameCell(row)
            }
            .width(min: 140, ideal: 200)

            TableColumn(L10n.string("Description"), value: \.summary) { row in
                Text(row.summary).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 160, ideal: 320)

            TableColumn(L10n.string("Version"), value: \.version) { row in
                Text(row.version).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 80, ideal: 120)

            TableColumn(L10n.string("Type"), value: \.kind.rawValue) { row in
                KindPill(kind: row.kind)
            }
            .width(min: 64, ideal: 80)

            TableColumn(L10n.string("Outdated"), value: \.outdatedRank) { row in
                outdatedCell(row)
            }
            .width(min: 56, ideal: 72)
        }
        .onChange(of: selectedID, openSelected)
    }

    private var tableNoDescription: some View {
        Table(model.sortedLibraryRows, selection: $selectedID, sortOrder: $model.librarySort) {
            TableColumn(L10n.string("Name"), value: \.name) { row in
                nameCell(row)
            }
            .width(min: 140, ideal: 240)

            TableColumn(L10n.string("Version"), value: \.version) { row in
                Text(row.version).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 80, ideal: 120)

            TableColumn(L10n.string("Type"), value: \.kind.rawValue) { row in
                KindPill(kind: row.kind)
            }
            .width(min: 64, ideal: 80)

            TableColumn(L10n.string("Outdated"), value: \.outdatedRank) { row in
                outdatedCell(row)
            }
            .width(min: 56, ideal: 72)
        }
        .onChange(of: selectedID, openSelected)
    }

    /// The Name cell shared by both table variants — icon + name/friendly-name,
    /// with an inline severity dot (after the name) when the package has known
    /// vulnerabilities. Shared so the dot lands in BOTH the AI-on and AI-off
    /// column sets without duplicating the cell body (the column SET differs
    /// between variants, but the Name cell is identical — see the variant note).
    @ViewBuilder
    private func nameCell(_ row: LibraryRow) -> some View {
        HStack(spacing: 8) {
            PackageIcon(model: model, token: row.name, kind: row.kind)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.name)
                    if let severity = row.maxSeverity {
                        SeverityDot(severity: severity, count: row.vulnCount)
                    }
                    if let badge = row.deprecation.badge {
                        DeprecationBadge(kind: badge, reason: row.deprecation.activeReason)
                    }
                }
                if !row.friendlyName.isEmpty {
                    Text(row.friendlyName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func outdatedCell(_ row: LibraryRow) -> some View {
        if row.isOutdated {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.orange)
                .help(L10n.string("Update available"))
        }
    }

    private func openSelected() {
        guard let id = selectedID,
              let pkg = model.installed.first(where: { $0.id == id }) else { return }
        model.openDetail(pkg)
    }
}

#if DEBUG
#Preview("Library") {
    LibraryView(model: .preview())
        .frame(width: 820, height: 560)
}
#endif

struct PlaceholderView: View {
    let section: Section

    var body: some View {
        ContentUnavailableView(
            section.rawValue,
            systemImage: section.symbol,
            description: Text("Wired in the full port. The spike proves Dashboard + Library end-to-end.")
        )
    }
}

/// Sidebar footer brew-health row — a colored SF Symbol dot + short label, with
/// a tooltip and a click-to-re-probe action. The native analogue of the Tauri
/// footer status button (`Sidebar.svelte:321-334`): green = ready, amber =
/// running, red = missing, muted = unknown (first probe in flight). Stock plain
/// `Button` in a thin bar; no chrome overrides.
struct BrewStatusRow: View {
    @Bindable var model: AppModel

    var body: some View {
        Button {
            Task { await model.reprobeBrew() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(dotColor)
                Text(model.brewShortLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .help(model.brewStatusTooltip)
    }

    private var dotColor: Color {
        switch model.brewHealth {
        case .ready:   return .green
        case .running: return .orange
        case .missing: return .red
        case .unknown: return .secondary
        }
    }
}

/// Sidebar footer vulnerable-package row — a red dot + "N vulnerable" label that
/// opens the Library Vulnerable filter on click. Sits ABOVE the brew-health row,
/// mirroring the Tauri sidebar footer vuln badge. Shown only when scanning is
/// enabled AND the install-wide scan has surfaced at least one finding (so it
/// no-ops cleanly when vuln scanning is off / nothing is vulnerable). Stock plain
/// `Button` matching `BrewStatusRow`'s styling; no chrome overrides.
struct VulnFooterRow: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.settings.vulnerabilityScanningAllowed, model.vulnerableCount > 0 {
            Button {
                model.openVulnerableInLibrary()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.red)
                    Text(L10n.vulnerablePackages(model.vulnerableCount))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .help(L10n.vulnerablePackagesHelp(model.vulnerableCount))
        }
    }
}
