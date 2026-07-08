import SwiftUI

/// ⌘K command palette — a stock `.sheet` overlay mirroring the Tauri
/// `CommandPalette.svelte`. A search field over a grouped `List` of:
///   1. Installed packages — top ~8 name matches (`AppModel.paletteInstalled`).
///   2. Index — top ~10 catalog matches, de-duped vs installed
///      (`AppModel.paletteCatalog`; the in-memory catalog is the native analog
///      of Tauri's `local_search`, which replaced `brew search` in v0.3.1).
///   3. Commands — open sections, toggle the Activity drawer, refresh.
/// Selecting a package opens its detail (Library if installed, Discover if not);
/// selecting a command runs it. Up/Down move the highlight, Enter activates, Esc
/// closes (handled by the enclosing `.sheet`). No custom window/material — a
/// stock sheet with a `List`.
struct CommandPaletteView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// The currently highlighted item's flat index across all groups.
    @State private var selectedIndex = 0
    /// Debounce token — bumped on each keystroke; the catalog only needs loading
    /// (not a network call) so the "debounce" just defers the first heavy
    /// `loadCatalog` until typing settles, matching the Tauri 300ms feel.
    @State private var loadTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    // MARK: - Result model

    /// One palette row — a package (installed or catalog) or a command.
    private enum Item: Identifiable {
        case package(token: String, kind: InstalledPackage.Kind, homepage: String, installed: Bool)
        case command(id: String, label: String, shortcut: String?, run: () -> Void)

        var id: String {
            switch self {
            case .package(let token, let kind, _, _): return "pkg:\(kind.rawValue):\(token)"
            case .command(let id, _, _, _):           return "cmd:\(id)"
            }
        }
    }

    private struct Group: Identifiable {
        let label: String
        let items: [Item]
        var id: String { label }
    }

    // MARK: - Derived groups (mirrors CommandPalette.svelte `groups`)

    private var commands: [Item] {
        [
            .command(id: "dashboard", label: L10n.string("Open Dashboard"), shortcut: "⌘0") { model.go(toSectionNumber: 0) },
            .command(id: "library",   label: L10n.string("Open Library"),   shortcut: "⌘1") { model.go(toSectionNumber: 1) },
            .command(id: "discover",  label: L10n.string("Open Discover"),  shortcut: "⌘2") { model.go(toSectionNumber: 2) },
            .command(id: "trending",  label: L10n.string("Open Trending"),  shortcut: "⌘3") { model.go(toSectionNumber: 3) },
            .command(id: "snapshots", label: L10n.string("Open Snapshots"), shortcut: "⌘4") { model.go(toSectionNumber: 4) },
            .command(id: "services",  label: L10n.string("Open Services"),  shortcut: "⌘5") { model.go(toSectionNumber: 5) },
            .command(id: "activity",  label: L10n.string("Open Activity"),  shortcut: "⌘6") { model.go(toSectionNumber: 6) },
            .command(id: "drawer",    label: L10n.string("Toggle Activity drawer"), shortcut: "⌘L") { model.toggleDrawer() },
            .command(id: "refresh",   label: L10n.string("Refresh"), shortcut: "⌘R") { Task { await model.refreshCurrent() } },
        ]
    }

    private var groups: [Group] {
        var out: [Group] = []

        let installed = model.paletteInstalled(query)
        if !installed.isEmpty {
            out.append(Group(label: L10n.string("Installed"), items: installed.map {
                .package(token: $0.name, kind: $0.kind, homepage: "", installed: true)
            }))
        }

        let index = model.paletteCatalog(query)
        if !index.isEmpty {
            out.append(Group(label: L10n.string("Index"), items: index.map {
                .package(token: $0.token, kind: $0.kind, homepage: $0.homepage, installed: false)
            }))
        }

        // Commands filter by label when there's a query (matches the Tauri
        // `commandHits`); with an empty query the full command list shows.
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let cmds = q.isEmpty ? commands : commands.filter {
            if case .command(_, let label, _, _) = $0 { return label.lowercased().contains(q) }
            return false
        }
        if !cmds.isEmpty {
            out.append(Group(label: L10n.string("Commands"), items: cmds))
        }
        return out
    }

    /// All items flattened in display order — the index space for keyboard nav.
    private var flatItems: [Item] { groups.flatMap(\.items) }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
            Divider()
            footer
        }
        .frame(width: 640, height: 420)
        .task { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.string("Type a command, package, or section."), text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit(activateSelected)
                .onChange(of: query) { _, _ in onQueryChange() }
            Text("Esc").font(.caption.monospaced()).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: .rect(cornerRadius: 4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Arrow-key nav + Enter on the field itself (the field keeps focus).
        // Esc dismisses explicitly — a macOS `.sheet` with a focused TextField
        // doesn't reliably auto-close on Escape, so handle it here.
        .onKeyPress(.upArrow)   { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1);  return .handled }
        .onKeyPress(.return)    { activateSelected(); return .handled }
        .onKeyPress(.escape)    { dismiss(); return .handled }
    }

    @ViewBuilder
    private var results: some View {
        if flatItems.isEmpty {
            ContentUnavailableView(L10n.string("No results"), systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    // Flat running index across groups so the highlight + Enter
                    // map to `flatItems` (mirrors the Tauri global `idx`).
                    let indexed = flatIndexed()
                    ForEach(groups) { group in
                        SwiftUI.Section(group.label.uppercased()) {
                            ForEach(group.items) { item in
                                let idx = indexed[item.id] ?? 0
                                row(item, isSelected: idx == selectedIndex)
                                    .id(idx)
                                    .contentShape(.rect)
                                    .onTapGesture { selectedIndex = idx; activateSelected() }
                                    .listRowBackground(
                                        idx == selectedIndex ? Color.accentColor.opacity(0.20) : Color.clear
                                    )
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .onChange(of: selectedIndex) { _, idx in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(idx, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: Item, isSelected: Bool) -> some View {
        switch item {
        case .package(let token, let kind, let homepage, let installed):
            HStack(spacing: 8) {
                PackageIcon(model: model, token: token, kind: kind, homepage: homepage, size: 18)
                Text(token)
                Spacer()
                Text(installed ? "\(L10n.packageKind(kind)) · \(L10n.display("installed"))" : L10n.packageKind(kind))
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .command(_, let label, let shortcut, _):
            HStack(spacing: 8) {
                Image(systemName: "command").foregroundStyle(.secondary).frame(width: 18)
                Text(label)
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            legend("↑↓", L10n.string("keyboard.navigate"))
            legend("⏎", L10n.string("keyboard.open"))
            legend("esc", L10n.string("keyboard.close"))
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func legend(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.caption.monospaced())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: .rect(cornerRadius: 4))
            Text(label)
        }
    }

    // MARK: - Behavior

    /// Map each item id → its flat index, so per-row views can resolve their
    /// position without re-flattening for every row.
    private func flatIndexed() -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, item) in flatItems.enumerated() { map[item.id] = i }
        return map
    }

    private func onQueryChange() {
        // Keep the highlight in range as results shrink/grow.
        selectedIndex = 0
        // The catalog backs the Index group; load it (idempotent) on the first
        // 2+ char query so index hits can appear. Debounced ~300ms to match the
        // Tauri search debounce and avoid loading on a single keystroke.
        loadTask?.cancel()
        guard query.trimmingCharacters(in: .whitespaces).count >= 2, model.catalog.isEmpty else { return }
        loadTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.loadCatalog()
        }
    }

    private func move(_ delta: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        selectedIndex = min(max(0, selectedIndex + delta), count - 1)
    }

    private func activateSelected() {
        let items = flatItems
        guard items.indices.contains(selectedIndex) else { return }
        switch items[selectedIndex] {
        case .command(_, _, _, let run):
            run()
            dismiss()
        case .package(let token, let kind, _, let installed):
            // Route to the package's detail (Library if installed, Discover if
            // not), mirroring the Tauri `activate` path.
            model.selection = installed ? .library : .discover
            model.openDetail(InstalledPackage(name: token, version: "", kind: kind))
            dismiss()
        }
    }
}

#if DEBUG
#Preview("Command palette") {
    CommandPaletteView(model: .preview())
}
#endif
