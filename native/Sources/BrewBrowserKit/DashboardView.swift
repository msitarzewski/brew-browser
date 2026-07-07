import SwiftUI
import Charts
import AppKit

/// Dashboard — feature parity with the Tauri Dashboard.svelte. Sections, in
/// order: hero stat strip (installed · updates · brew version/prefix),
/// "Updates available" (kind pills, Choose…, Upgrade all (N), +N in Library),
/// Composition (stacked bar + on-request/pinned chips), Storage (full
/// breakdown with paths, open-in-Finder, total). Stock SwiftUI throughout;
/// every number is live brew data.
struct DashboardView: View {
    @Bindable var model: AppModel

    /// True when the content pane is wide enough to pair cards two-across.
    @State private var wide = false

    var body: some View {
        ScrollView {
            if !model.dashboardLoaded {
                ProgressView("Reading your Homebrew setup…")
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HeroStrip(model: model)
                    CatalogFreshnessStrip(model: model)
                    if model.outdatedCount > 0 { UpdatesCard(model: model) }

                    // Composition + Top categories sit side by side when the
                    // pane is wide enough, and stack when it's narrow (or the
                    // inspector is open). Updates and Storage stay full-width —
                    // they're tabular and want the room.
                    if wide {
                        // .fixedSize keeps each card's natural height, then
                        // maxHeight: .infinity stretches the shorter one to match
                        // the taller — so the two cards align bottom-to-bottom.
                        HStack(alignment: .top, spacing: 16) {
                            CompositionCard(model: model, compact: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if !model.categories.isEmpty {
                                CategoriesCard(model: model)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        CompositionCard(model: model)
                        if !model.categories.isEmpty { CategoriesCard(model: model) }
                    }

                    if model.githubStatsEligible { GitHubCard(model: model) }

                    // Exposure card — opt-in only; hidden entirely when
                    // Settings → Vulnerability Scanning is off so the dashboard
                    // doesn't nag users who haven't enabled it (mirrors the
                    // Tauri `exposureVisible` gate).
                    if model.settings.vulnerabilityScanningAllowed { ExposureCard(model: model) }

                    StorageCard(model: model)
                }
                .padding(20)
                // Fill the available content width (no fixed cap) so the
                // Dashboard uses the full pane instead of hugging the left.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Measure the pane width to drive the two-across vs stacked breakpoint.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            wide = newWidth > 980
        }
        .task {
            if !model.dashboardLoaded { await model.loadDashboard() }
        }
    }
}

// MARK: - Hero strip

struct HeroStrip: View {
    @Bindable var model: AppModel

    var body: some View {
        // Three equal flexible columns that always span the full width, like
        // the Tauri hero strip — they shrink together rather than leaving a gap
        // on the right (StatTile's minimumScaleFactor handles narrow widths).
        HStack(spacing: 16) {
            StatTile(value: "\(model.totalPackages)", label: "installed", symbol: "shippingbox") {
                model.openLibrary()
            }
            StatTile(
                value: model.outdatedLoading ? "…" : (model.outdatedCount == 0 ? L10n.display("All current") : "\(model.outdatedCount)"),
                label: model.outdatedLoading ? L10n.display("checking updates") : (model.outdatedCount == 0 ? "" : L10n.display("updates available")),
                symbol: "arrow.up.circle"
            ) { if model.outdatedCount > 0 { model.openOutdatedInLibrary() } }
            .disabled(model.outdatedLoading || model.outdatedCount == 0)

            StatTile(value: model.brewVersion, label: model.brewPrefix, symbol: "internaldrive", monospaceValue: true, action: nil)
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    var monospaceValue = false
    var action: (() -> Void)?

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(monospaceValue ? .title3.weight(.semibold).monospaced() : .title2.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    if !label.isEmpty {
                        Text(L10n.display(label)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(.rect)
        }
        .onTapGesture { action?() }
    }
}

// MARK: - Catalog freshness

/// Dashboard catalog-freshness strip — "Catalog: N days old (source)" with a
/// Refresh button that re-downloads the index from brew.sh. Amber when stale.
/// Parity with the Tauri `Dashboard.svelte` catalog line (`:524-553`); the
/// Refresh routes through `AppModel.refreshCatalogFromBrewSh` (Offline-gated).
struct CatalogFreshnessStrip: View {
    @Bindable var model: AppModel

    var body: some View {
        let stale = model.catalogIsStale
        HStack(spacing: 8) {
            Text("\(L10n.display("Catalog")): \(Text(model.catalogDaysOldLabel).fontWeight(.semibold))")
                .foregroundStyle(.secondary)
            if let src = model.catalogSummary?.source {
                Text("(\(L10n.display(src.rawValue)))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let err = model.catalogRefreshError {
                Text(err)
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(1).truncationMode(.tail)
            }
            Button {
                Task { await model.refreshCatalogFromBrewSh() }
            } label: {
                if model.catalogRefreshing {
                    // Live spinner (not a static rotate-arrow) so the button
                    // shows real motion while the sync runs.
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(L10n.display("Refreshing…"))
                    }
                } else if stale {
                    Label(L10n.display("Refresh from brew.sh →"), systemImage: "arrow.clockwise")
                } else {
                    Label(L10n.display("Refresh"), systemImage: "arrow.clockwise")
                }
            }
            .controlSize(.small)
            .disabled(model.catalogRefreshing)
            .help("Re-download the Homebrew catalog from formulae.brew.sh")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(stale ? AnyShapeStyle(.orange.opacity(0.12)) : AnyShapeStyle(.quaternary),
                    in: .rect(cornerRadius: 8))
        .task { await model.loadCatalogSummary() }
    }
}

// MARK: - Updates available

struct UpdatesCard: View {
    @Bindable var model: AppModel
    /// Drives the curated multi-select upgrade sheet ("Choose…").
    @State private var showUpgradeSheet = false

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                // Header row: title link + Choose… + Upgrade all (N)
                HStack {
                    Button {
                        model.openOutdatedInLibrary()
                    } label: {
                        HStack(spacing: 4) {
                            Text(L10n.display("Updates available")).font(.headline)
                            Image(systemName: "arrow.right").font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    // No "Update" button here — the catalog "Refresh" above runs
                    // `brew update` + re-pulls the catalog, so a separate Update
                    // was redundant (and Tauri's Updates card has only Choose… +
                    // Upgrade all).
                    Button(L10n.display("Choose…")) { showUpgradeSheet = true }
                        .controlSize(.small)
                    Button {
                        Task { await model.upgradeAll(greedy: LocalPrefs.shared.greedyUpgrade) }
                    } label: {
                        Label(L10n.isRussian ? "Обновить всё (\(model.outdatedCount))" : "Upgrade all (\(model.outdatedCount))", systemImage: "arrow.up.circle")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 8)

                ForEach(model.outdatedPreview) { p in
                    Button {
                        model.openDetail(InstalledPackage(name: p.name, version: p.installedVersion, kind: p.kind))
                    } label: {
                        HStack(spacing: 10) {
                            // Name column — flexible, takes remaining space.
                            HStack(spacing: 6) {
                                Text(p.name)
                                // Per-row severity dot from the install-wide scan
                                // (no-ops when scanning is off / package is clean).
                                if let vuln = model.vulnSummary(for: p.name),
                                   let severity = vuln.maxSeverity {
                                    SeverityDot(severity: severity, count: vuln.total)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Kind column — fixed width so pills align vertically.
                            KindPill(kind: p.kind)
                                .frame(width: 84, alignment: .leading)
                            // Version column — fixed width, right-aligned.
                            Text("\(p.installedVersion) → \(p.currentVersion)")
                                .font(.callout).foregroundStyle(.secondary).monospaced()
                                // Keep the "old → new" pair on one line; scale down
                                // to fit rather than wrap/truncate long cask versions
                                // (e.g. docker-desktop's "4.77.0,228796"). Parity with
                                // the Tauri Dashboard's white-space:nowrap.
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: 200, alignment: .trailing)
                        }
                        .contentShape(.rect)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        // Keep the row highlighted while its detail inspector is
                        // open (the list has no Table selection of its own).
                        .background(
                            model.showDetail && model.detailPackage?.name == p.name
                                ? AnyShapeStyle(.selection)
                                : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                    if p.id != model.outdatedPreview.last?.id { Divider() }
                }

                if model.outdatedCount > model.outdatedPreview.count {
                    HStack {
                        Button(L10n.moreInLibrary(model.outdatedCount - model.outdatedPreview.count)) {
                            model.openOutdatedInLibrary()
                        }
                        .buttonStyle(.link)
                        Spacer()
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.top, 2)
        }
        .sheet(isPresented: $showUpgradeSheet) {
            UpgradeSheet(model: model) { showUpgradeSheet = false }
        }
    }
}

/// formula/cask kind pill, like the Tauri `<Pill>`.
struct KindPill: View {
    let kind: InstalledPackage.Kind
    var body: some View {
        Text(kind.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(kind == .formula ? Color.blue.opacity(0.18) : Color.orange.opacity(0.18),
                        in: .capsule)
            .foregroundStyle(kind == .formula ? .blue : .orange)
    }
}

// MARK: - Composition (stacked bar + chips)

struct CompositionCard: View {
    @Bindable var model: AppModel
    /// When paired side-by-side with Top categories, render a pie (fills a
    /// square-ish card); when full-width, render the stacked bar.
    var compact = false

    private var total: Int { max(1, model.formulaCount + model.caskCount) }
    private var formulaFraction: CGFloat { CGFloat(model.formulaCount) / CGFloat(total) }

    private var pieData: [(label: String, count: Int)] {
        [(L10n.display("Formulae"), model.formulaCount), (L10n.display("Casks"), model.caskCount)]
    }

    private var formulaPct: Double { Double(model.formulaCount) / Double(total) * 100 }
    private var caskPct: Double { Double(model.caskCount) / Double(total) * 100 }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Title row — pills (on request / pinned) live here now.
                HStack {
                    Text(L10n.display("Composition")).font(.headline)
                    Spacer()
                    Chip(text: L10n.display("\(model.onRequestCount) on request"))
                    Chip(text: L10n.display("\(model.pinnedCount) pinned"))
                }

                if compact {
                    // Pie + ranked legend, mirroring the Top-categories layout.
                    HStack(alignment: .center, spacing: 20) {
                        Chart(pieData, id: \.label) { item in
                            SectorMark(angle: .value("Count", item.count), angularInset: 1.5)
                                .cornerRadius(4)
                                .foregroundStyle(by: .value("Kind", item.label))
                        }
                        .chartForegroundStyleScale([L10n.display("Formulae"): Color.blue, L10n.display("Casks"): Color.orange])
                        .chartLegend(.hidden)
                        .frame(width: 180, height: 180)
                        .padding(.vertical, 16)
                        .padding(.leading, 16)

                        VStack(spacing: 0) {
                            compositionLegendRow(color: .blue, label: L10n.display("Formulae"),
                                                 count: model.formulaCount, pct: formulaPct)
                            compositionLegendRow(color: .orange, label: L10n.display("Casks"),
                                                 count: model.caskCount, pct: caskPct)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    // Stacked horizontal bar — single rounded track with two
                    // segments meeting flush (no gap), clipped to a capsule.
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            Rectangle().fill(.blue)
                                .frame(width: geo.size.width * formulaFraction)
                            Rectangle().fill(.orange)
                        }
                        .clipShape(.capsule)
                    }
                    .frame(height: 14)

                    HStack(spacing: 16) {
                        LegendDot(color: .blue, text: L10n.formulaeCount(model.formulaCount))
                        LegendDot(color: .orange, text: L10n.casksCount(model.caskCount))
                        Spacer()
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// Legend row matching the Top-categories format: dot · label · count · %.
    private func compositionLegendRow(color: Color, label: String, count: Int, pct: Double) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.callout)
            Spacer(minLength: 12)
            Text("\(count)").font(.callout.monospacedDigit())
            Text(String(format: "%.1f%%", pct))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }
}

struct LegendDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 11, height: 11)
            Text(text).font(.callout)
        }
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
    }
}

// MARK: - Top categories (donut + ranked legend, with hover)

struct CategoriesCard: View {
    @Bindable var model: AppModel
    @State private var hovered: String?

    /// Stable palette across slices + legend.
    private let palette: [Color] = [
        .blue, .orange, .green, .yellow, .purple, .pink, .teal, .red, .gray
    ]

    private func color(_ index: Int) -> Color { palette[index % palette.count] }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.display("Top categories in your library")).font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .center, spacing: 20) {
                    donut
                        .frame(width: 180, height: 180)
                        .padding(.vertical, 16)
                        .padding(.leading, 16)

                    VStack(spacing: 0) {
                        ForEach(Array(model.categories.enumerated()), id: \.element.id) { idx, cat in
                            legendRow(idx: idx, cat: cat)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 2)
        }
    }

    private var donut: some View {
        Chart(Array(model.categories.enumerated()), id: \.element.id) { idx, cat in
            SectorMark(
                angle: .value("Count", cat.count),
                innerRadius: .ratio(0.6),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(color(idx))
            .opacity(hovered == nil || hovered == cat.slug ? 1 : 0.3)
        }
        .chartLegend(.hidden)
    }

    private func legendRow(idx: Int, cat: CategoryBreakdown) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color(idx)).frame(width: 10, height: 10)
            // Per-category glyph (matches the Tauri legend's icon column).
            Image(systemName: cat.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(L10n.display(cat.label))
                .font(.callout)
                .fontWeight(hovered == cat.slug ? .semibold : .regular)
            Spacer(minLength: 12)
            Text("\(cat.count)")
                .font(.callout.monospacedDigit())
            Text(String(format: "%.1f%%", cat.fraction * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            hovered == cat.slug ? Color.secondary.opacity(0.12) : .clear,
            in: .rect(cornerRadius: 6)
        )
        .contentShape(.rect)
        .onHover { inside in
            hovered = inside ? cat.slug : (hovered == cat.slug ? nil : hovered)
        }
        // Click a category → show your INSTALLED packages in it (Library),
        // not the whole Discover catalog. See #58.
        .onTapGesture { model.jumpToLibraryCategory(cat.slug) }
        .help(L10n.isRussian ? "Показать установленные пакеты в категории \(L10n.display(cat.label))" : "Show your installed \(cat.label) packages")
    }
}

// MARK: - Storage (full breakdown)

struct StorageCard: View {
    @Bindable var model: AppModel

    // Issue #80 — cache cleanup confirm gate + toggles (local UI state).
    @State private var showCleanupConfirm = false
    @State private var cleanupVerbose = true
    @State private var cleanupScrub = false  // opt-in: also remove latest-version downloads

    private func human(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.display("Storage")).font(.headline)
                    Spacer()
                    Text(L10n.display("\(human(model.storageTotalBytes)) total"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                if model.storage.isEmpty && model.storageLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.display("Measuring disk usage…")).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 7)
                }
                ForEach(model.storage) { item in
                    HStack(spacing: 12) {
                        Text(L10n.display(item.label)).frame(width: 160, alignment: .leading)
                        Text(item.path)
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(human(item.bytes)).font(.callout.monospaced())
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 7)
                    if item.id != model.storage.last?.id { Divider() }
                }

                // Issue #80 — cache maintenance: brew doctor (diagnostics) +
                // cleanup (reclaim cached downloads), both streamed into Activity.
                Divider().padding(.vertical, 4)
                HStack(spacing: 8) {
                    Button {
                        Task { await model.runDoctor() }
                    } label: {
                        Label(model.doctorRunning ? L10n.display("Running…") : L10n.display("Run brew doctor"),
                              systemImage: "stethoscope")
                    }
                    .disabled(model.maintenanceBusy)

                    Button {
                        showCleanupConfirm.toggle()
                    } label: {
                        Label(model.cleanupRunning ? L10n.display("Cleaning…") : L10n.display("Clean up cache…"),
                              systemImage: "trash")
                    }
                    .disabled(model.maintenanceBusy)

                    if let bytes = model.cleanupReclaimableBytes, bytes > 0 {
                        Text(L10n.display("frees ~\(human(bytes))"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.top, 2)

                if showCleanupConfirm {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(cleanupConfirmText)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle(L10n.display("Scrub — also remove the latest versions' cached downloads (more aggressive)"), isOn: $cleanupScrub)
                            .font(.callout)
                        Toggle(L10n.display("Verbose — list every file removed"), isOn: $cleanupVerbose)
                            .font(.callout)
                        HStack {
                            Spacer()
                            Button(L10n.display("Cancel")) { showCleanupConfirm = false }
                            Button(L10n.display("Clean up"), role: .destructive) {
                                showCleanupConfirm = false
                                Task { await model.runCleanup(scrub: cleanupScrub, verbose: cleanupVerbose) }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 6)
                }
            }
            .padding(.top, 2)
        }
    }

    /// Plain-English description of what cleanup removes, with the reclaimable
    /// figure when known. Mirrors the Tauri confirm copy.
    private var cleanupConfirmText: String {
        let freeing: String
        if let bytes = model.cleanupReclaimableBytes, bytes > 0 {
            freeing = L10n.isRussian ? ", освободится примерно \(human(bytes))" : ", freeing about \(human(bytes))"
        } else {
            freeing = ""
        }
        let scrubNote = cleanupScrub
            ? (L10n.isRussian ? " Также удалит загрузки текущих версий (--scrub)." : " Also clears the current versions' downloads (--scrub).")
            : ""
        if L10n.isRussian {
            return "Удаляет устаревшие кэшированные загрузки\(freeing).\(scrubNote) "
                + "Установленные пакеты не затрагиваются."
        }
        return "Removes outdated cached downloads\(freeing).\(scrubNote) "
            + "Your installed packages are not affected."
    }
}

// MARK: - Exposure (vulnerability surfacing)

/// Dashboard Exposure card — install-wide vulnerability surface. Parity with
/// the Tauri `Dashboard.svelte` Exposure section. Three states, mirroring the
/// Tauri card: never-scanned CTA, clean positive state, and per-severity counts
/// with the "X of N" summary + "View vulnerable packages". The parent gates
/// rendering on `vulnerabilityScanningAllowed` (opt-in), so this view never has
/// to render a "scanning disabled" stub.
struct ExposureCard: View {
    @Bindable var model: AppModel

    /// "Last scan: 2 hours ago" / "never". Same RelativeDateTimeFormatter UX
    /// language as the Tauri card's `Intl.RelativeTimeFormat`.
    private var lastScanLabel: String {
        guard let at = model.vulnLastScannedAt else { return "never" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return fmt.localizedString(for: at, relativeTo: Date())
    }

    var body: some View {
        let exposure = model.vulnExposure
        let scanned = model.vulnLastScannedAt != nil
        // A confident green "all clean" is only honest when we just scanned this
        // session. Stale/cached or never-scanned must NOT reassure.
        let freshClean = model.vulnScannedThisSession && exposure.vulnerablePackages == 0
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Header: shield icon (green ONLY when freshly clean) + last-scan + Scan now.
                HStack {
                    Image(systemName: freshClean ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(freshClean ? .green : .orange)
                    Text("Exposure").font(.headline)
                    Spacer()
                    if scanned {
                        Text("Last scan: \(lastScanLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await model.scanAllVulns() }
                    } label: {
                        if model.vulnScanAllLoading {
                            // Live spinner, not a static rotate-arrow.
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text("Scanning…")
                            }
                        } else {
                            Label("Scan now", systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .disabled(model.vulnScanAllLoading)
                    .help("Re-run brew vulns against every installed formula")
                }

                if !scanned {
                    // Never scanned — a HAZARD, not a gentle suggestion. We must
                    // not imply safety we haven't verified.
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not scanned yet.").fontWeight(.semibold)
                            Text("We haven't checked your installed packages for known vulnerabilities. Run a scan when you can. (Vulnerability scanning is configured in Settings → Security.)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if exposure.vulnerablePackages == 0 && !freshClean {
                    // Clean LAST time, but the scan is stale (loaded from cache /
                    // not run this session). Don't claim all-clear — caution +
                    // re-scan prompt.
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No advisories as of the last scan (\(lastScanLabel)).").fontWeight(.semibold)
                            Text("Packages may have changed since. Re-scan to confirm.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                } else if exposure.vulnerablePackages == 0 {
                    // Freshly clean — a GOOD result; frame it positively.
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No known vulnerabilities.").fontWeight(.semibold)
                            Text("All installed packages are clean of advisories known to brew vulns.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    // Findings — per-severity counts + "X of N" summary line.
                    // Severity tones mirror the Tauri chips exactly
                    // (Dashboard.svelte `exp-sev--*`): critical+high danger (red),
                    // medium warning (amber/orange), low info (blue), unknown
                    // neutral (gray).
                    HStack(spacing: 16) {
                        sevCount(exposure.critical, L10n.severity(.critical), .red)
                        sevCount(exposure.high, L10n.severity(.high), .red)
                        sevCount(exposure.medium, L10n.severity(.medium), .orange)
                        sevCount(exposure.low, L10n.severity(.low), .blue)
                        if exposure.unknown > 0 { sevCount(exposure.unknown, L10n.severity(.unknown), .gray) }
                        Spacer()
                    }
                    // Summary line — identical to the Tauri Exposure card
                    // (Dashboard.svelte): "<N> findings across <M> of <T> installed
                    // packages · source: <live|cache>". The chips count individual
                    // advisories (findings), so the line spells out the findings
                    // total separately from the package count; the source label
                    // makes a stale (cache) scan visibly distinct from a fresh one.
                    Text(L10n.exposureSummary(
                        findings: exposure.total,
                        vulnerablePackages: exposure.vulnerablePackages,
                        totalPackages: model.totalPackages,
                        source: model.vulnSource?.rawValue
                    ))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(L10n.string("security.viewVulnerablePackages")) {
                        model.openVulnerableInLibrary()
                    }
                    .buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
        // No auto-scan on appear: a full install-wide sweep is multi-minute, so
        // launching straight into "Scanning…" every time is the wrong default.
        // The card shows the last persisted result (loaded at launch) or a
        // "Scan now" CTA; scanning is user-initiated via the header button.
    }

    /// One severity count chip — bold number + lowercase label, toned by color.
    private func sevCount(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(n)").font(.callout.weight(.semibold)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// GitHub personal-stats card — "you've starred N of M installed packages with
/// GitHub homepages." Parity with the Tauri Dashboard card. Only shown when
/// signed in + GitHub allowed (gated by the parent on `githubStatsEligible`).
struct GitHubCard: View {
    @Bindable var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label { Text("GitHub").font(.headline) } icon: { GithubMarkIcon(size: 15) }
                    Spacer()
                    if let user = model.githubStatus?.username {
                        Text("@\(user)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 10)

                if model.githubStatsLoaded && model.githubHomepageTotal == 0 {
                    Text(L10n.string("github.noInstalledHomepages"))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !model.githubStatsLoaded {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.githubCheckingStarred(total: model.githubHomepageTotal))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(L10n.githubStarredSummary(starred: model.githubStarredCount, total: model.githubHomepageTotal))
                            .font(.callout)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
    }
}

#if DEBUG
#Preview("Dashboard") {
    DashboardView(model: .preview())
        .frame(width: 980, height: 800)
}
#endif
