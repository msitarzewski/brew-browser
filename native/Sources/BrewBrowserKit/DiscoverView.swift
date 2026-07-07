import SwiftUI

/// Discover — browse the full Homebrew catalog (available packages, not just
/// installed). Same stock `Table` + selection→inspector pattern as Library,
/// with a category `Picker` filter bar and async app-icon resolution (Appcasks
/// → Google favicon → SF Symbol). Reuses `globalQuery` as the single search
/// field (no second `.searchable` — see LibraryView for why).
struct DiscoverView: View {
    @Bindable var model: AppModel
    @State private var prefs = LocalPrefs.shared
    /// Session-only dismissal of the stale-catalog banner (mirrors the Tauri
    /// `bannerDismissed` — resets on relaunch, not persisted).
    @State private var bannerDismissed = false

    @State private var selectedID: DiscoverRow.ID?

    /// True when nothing is narrowing the catalog: no search text and no
    /// category chip. In this state Discover shows the browse grid (AI on) /
    /// recent chips, mirroring the Tauri idle Discover.
    private var isIdle: Bool {
        model.globalQuery.trimmingCharacters(in: .whitespaces).isEmpty
            && model.discoverCategory == nil
    }

    var body: some View {
        Group {
            if model.catalogLoading && model.catalog.isEmpty {
                ProgressView("Loading the Homebrew catalog…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if model.catalogIsStale && !bannerDismissed { staleBanner }
                    filterBar
                    Divider()
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .task { await model.loadCatalog() }
        .task { await model.loadCatalogSummary() }
        // Record a committed search term for the recent-search chips. The
        // toolbar `.searchable` lives on ContentView; we capture the term when
        // the live query settles to a non-empty value while browsing Discover.
        .onChange(of: model.globalQuery) { _, q in
            let trimmed = q.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 2 { model.recordDiscoverSearch(trimmed) }
        }
        .onChange(of: model.showDetail) { _, shown in
            if !shown { selectedID = nil }
        }
    }

    // Session-dismissable stale-catalog banner — amber strip with a one-click
    // "Refresh from brew.sh →". Parity with the Tauri Discover stale banner
    // (`Discover.svelte:149-180`); gated above on `catalogIsStale`.
    private var staleBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(L10n.isRussian
                 ? "Каталог устарел: \(model.catalogDaysOldLabel). Новые пакеты и сведения об устаревании могут отсутствовать."
                 : "Catalog is \(model.catalogDaysOldLabel). Newer packages and deprecations may be missing.")
                .font(.callout)
            Spacer()
            Button {
                Task { await model.refreshCatalogFromBrewSh() }
            } label: {
                if model.catalogRefreshing {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(L10n.display("Refreshing…"))
                    }
                } else {
                    Label(L10n.display("Refresh from brew.sh →"), systemImage: "arrow.clockwise")
                }
            }
            .controlSize(.small)
            .disabled(model.catalogRefreshing)
            Button {
                bannerDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss for this session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    // Category Picker, centered (matches Library's centered segmented filter).
    private var filterBar: some View {
        Picker("Category", selection: $model.discoverCategory) {
            Text(L10n.isRussian ? "Все категории" : "All Categories").tag(String?.none)
            ForEach(model.categoryList, id: \.slug) { cat in
                Text(L10n.display(cat.label)).tag(String?.some(cat.slug))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Idle browse (grid + recent chips) vs. the results table. The Tauri
    // Discover shows a category tile grid by default (AI on) and recent-search
    // chips above it; once a search or chip narrows the catalog, the list wins.
    @ViewBuilder
    private var content: some View {
        if isIdle && model.settings.aiFeaturesVisible && !model.categoryTiles.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !prefs.recentSearches.isEmpty { recentSearchesRow }
                    categoryGrid
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 0) {
                subgroupStrip
                table
            }
        }
    }

    // Co-occurrence sub-group chips for the selected category (feature #6).
    // Shown only when exactly one category is selected and no search is
    // narrowing the list (model.discoverSubgroups is empty otherwise). Each chip
    // narrows the table to one sub-group; "All" clears the drill-down. These are
    // co-occurrence buckets (a category a member ALSO carries), NOT a true
    // sub-taxonomy — the labels say "X + Y" / "General X" so the grouping is
    // never mistaken for a hierarchy. A lone "General X" bucket (a category whose
    // members are all solo) is suppressed: a single chip would look broken and
    // adds nothing over the flat list.
    @ViewBuilder
    private var subgroupStrip: some View {
        let groups = model.discoverSubgroups
        let onlyGeneral = groups.count == 1 && groups.first?.key == categorySubgroupGeneralKey
        if !groups.isEmpty && !onlyGeneral {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        subgroupChip(label: L10n.isRussian ? "Все" : "All", count: nil, key: nil)
                        ForEach(groups) { g in
                            subgroupChip(label: L10n.display(g.label), count: g.count, key: g.key)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                Divider()
            }
        }
    }

    @ViewBuilder
    private func subgroupChip(label: String, count: Int?, key: String?) -> some View {
        let active = model.discoverSubgroupKey == key
        Button {
            model.discoverSubgroupKey = key
        } label: {
            HStack(spacing: 5) {
                Text(label)
                if let count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.caption.weight(active ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(active ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary),
                        in: .capsule)
        }
        .buttonStyle(.plain)
        .help(key == categorySubgroupGeneralKey
              ? "Members of this category with no other category"
              : "Members also categorized here")
    }

    // Recent-search chips — click to re-run. Persisted in LocalPrefs
    // (UserDefaults); the Tauri equivalent kept these in memory only.
    private var recentSearchesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { prefs.clearRecentSearches() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            FlowRow(spacing: 8) {
                ForEach(prefs.recentSearches, id: \.self) { term in
                    Button {
                        model.globalQuery = term
                    } label: {
                        Text(term)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.quaternary, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // Category tile grid — SF Symbol + label + catalog count; click filters
    // Discover to that category (sets `discoverCategory`). Parity with the
    // Tauri tile grid (`Discover.svelte:330-343`). Icons are data-driven
    // (`iconSF` from categories.json).
    private var categoryGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)]
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.isRussian
                 ? "Просматривайте \(model.catalog.count) пакетов по категориям или используйте поиск выше."
                 : "Browse \(model.catalog.count) packages by category, or search above.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.categoryTiles) { tile in
                    Button {
                        model.discoverCategory = tile.slug
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tile.icon)
                                .font(.title2)
                                .foregroundStyle(.tint)
                            Text(L10n.display(tile.label))
                                .font(.callout.weight(.medium))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            Text("\(tile.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .padding(.vertical, 10)
                        .background(.quaternary, in: .rect(cornerRadius: 12))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var table: some View {
        let rows = model.sortedDiscoverRows
        if rows.isEmpty {
            if model.catalog.isEmpty {
                ContentUnavailableView("Catalog unavailable",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("The bundled package catalog couldn't be loaded."))
            } else if !model.globalQuery.isEmpty {
                ContentUnavailableView.search(text: model.globalQuery)
            } else {
                ContentUnavailableView("No packages",
                                       systemImage: "sparkles.rectangle.stack",
                                       description: Text("Nothing in this category."))
            }
        } else {
            // AI-gated Description column → two static column sets (a conditional
            // TableColumn inside one builder destabilizes NSTableColumn and
            // crashes on layout — same lesson as Library).
            if model.settings.aiFeaturesVisible {
                discoverTable(rows, showDescription: true)
            } else {
                discoverTable(rows, showDescription: false)
            }
        }
    }

    @ViewBuilder
    private func discoverTable(_ rows: [DiscoverRow], showDescription: Bool) -> some View {
        if showDescription {
            Table(rows, selection: $selectedID, sortOrder: $model.discoverSort) {
                TableColumn("Name", value: \.name) { iconNameCell($0) }.width(min: 160, ideal: 220)
                TableColumn("Description", value: \.summary) { r in
                    Text(r.summary).foregroundStyle(.secondary).lineLimit(1)
                }.width(min: 160, ideal: 300)
                TableColumn("Version", value: \.version) { r in
                    Text(r.version).foregroundStyle(.secondary).monospacedDigit()
                }.width(min: 70, ideal: 100)
                TableColumn("Type", value: \.kind.rawValue) { KindPill(kind: $0.kind) }.width(min: 64, ideal: 80)
                TableColumn("Installed", value: \.installedRank) { installedCell($0) }.width(min: 64, ideal: 80)
            }
            .onChange(of: selectedID, openSelected)
        } else {
            Table(rows, selection: $selectedID, sortOrder: $model.discoverSort) {
                TableColumn("Name", value: \.name) { iconNameCell($0) }.width(min: 200, ideal: 280)
                TableColumn("Version", value: \.version) { r in
                    Text(r.version).foregroundStyle(.secondary).monospacedDigit()
                }.width(min: 70, ideal: 100)
                TableColumn("Type", value: \.kind.rawValue) { KindPill(kind: $0.kind) }.width(min: 64, ideal: 80)
                TableColumn("Installed", value: \.installedRank) { installedCell($0) }.width(min: 64, ideal: 80)
            }
            .onChange(of: selectedID, openSelected)
        }
    }

    // Icon + name cell. Icon resolves async into model.iconCache (Appcasks →
    // Google favicon); formulae + unresolved casks show an SF Symbol.
    @ViewBuilder
    private func iconNameCell(_ row: DiscoverRow) -> some View {
        HStack(spacing: 8) {
            PackageIcon(model: model, token: row.token, kind: row.kind, homepage: row.homepage)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.token)
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
    private func installedCell(_ row: DiscoverRow) -> some View {
        if row.isInstalled {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Installed")
        }
    }

    private func openSelected() {
        guard let id = selectedID,
              let row = model.sortedDiscoverRows.first(where: { $0.id == id }) else { return }
        // Reuse the shared detail inspector — wrap the catalog row as a package.
        model.openDetail(InstalledPackage(name: row.token, version: row.version, kind: row.kind))
    }
}

/// A small app icon for any list row (Discover, Library, …): the resolved
/// cached image when present, else an SF Symbol. Triggers async resolution on
/// appear (casks only; formulae are CLI tools → terminal glyph). Shared so every
/// list shows the same real icons. `homepage` is only needed for the favicon
/// fallback; installed casks usually resolve via Appcasks token-only, so passing
/// "" is fine.
struct PackageIcon: View {
    @Bindable var model: AppModel
    let token: String
    let kind: InstalledPackage.Kind
    var homepage: String = ""
    var size: CGFloat = 20

    var body: some View {
        Group {
            if kind == .cask, let url = model.iconCache[token],
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                Image(systemName: kind == .cask ? "app.dashed" : "terminal")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: token) {
            await model.resolveIcon(token: token, kind: kind, homepage: homepage)
        }
    }
}

#if DEBUG
#Preview("Discover") {
    DiscoverView(model: .preview())
        .frame(width: 820, height: 560)
}
#endif
