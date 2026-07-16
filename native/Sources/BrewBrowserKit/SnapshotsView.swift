import SwiftUI
import AppKit

/// Snapshots — save / restore / import / export Brewfile snapshots, parity with
/// the Tauri `Snapshots.svelte`. Stock SwiftUI: a header action bar (New +
/// Import), a card list, per-card Restore/Export/Delete, a "New" sheet, and
/// `.confirmationDialog` for the destructive Restore/Delete. The dump/restore
/// brew runs stream into the shared Activity drawer (via `AppModel.startJob`).
struct SnapshotsView: View {
    @Bindable var model: AppModel

    @State private var showNewSheet = false
    @State private var newLabel = ""
    @State private var toDelete: Snapshot?
    @State private var toRestore: Snapshot?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.loadSnapshots() }
        .sheet(isPresented: $showNewSheet) { newSheet }
        .confirmationDialog(
            toRestore.map { L10n.isRussian ? "Восстановить из снимка «\($0.label)»?" : "Restore from “\($0.label)”?" } ?? "",
            isPresented: restoreBinding, titleVisibility: .visible, presenting: toRestore
        ) { snap in
            Button(L10n.string("Restore")) { toRestore = nil; Task { await model.restoreSnapshot(snap) } }
            Button(L10n.string("Cancel"), role: .cancel) { toRestore = nil }
        } message: { _ in
            Text(L10n.string("This installs packages from the snapshot. Existing packages are skipped."))
        }
        .confirmationDialog(
            toDelete.map { L10n.isRussian ? "Удалить снимок «\($0.label)»?" : "Delete snapshot “\($0.label)”?" } ?? "",
            isPresented: deleteBinding, titleVisibility: .visible, presenting: toDelete
        ) { snap in
            Button(L10n.string("Delete"), role: .destructive) { toDelete = nil; Task { await model.deleteSnapshot(snap) } }
            Button(L10n.string("Cancel"), role: .cancel) { toDelete = nil }
        } message: { _ in
            Text(L10n.string("The Brewfile will be removed from disk. This cannot be undone."))
        }
        .alert(L10n.string("Snapshot error"), isPresented: errorBinding, presenting: errorMessage) { _ in
            Button(L10n.string("OK"), role: .cancel) { errorMessage = nil }
        } message: { msg in Text(msg) }
    }

    // Trailing-aligned action bar (matches Tauri's panel-head: Import + New).
    private var headerBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button { importSnapshot() } label: {
                Label(L10n.string("Import…"), systemImage: "square.and.arrow.down")
            }
            Button { newLabel = defaultLabel(); showNewSheet = true } label: {
                Label(L10n.string("New Snapshot"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.snapshotsLoading && model.snapshots.isEmpty {
            ProgressView(L10n.string("Loading snapshots…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.snapshots.isEmpty {
            ContentUnavailableView {
                Label(L10n.string("No snapshots yet"), systemImage: "archivebox")
            } description: {
                Text(L10n.string("Save your current setup so you can restore it on another Mac. Snapshots live in ~/Library/Application Support/brew-browser/brewfiles/ — findable outside the app too."))
            }
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.snapshots) { card($0) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func card(_ snap: Snapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.label).font(.headline)
                        Text(metaLine(snap)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        Button { toRestore = snap } label: {
                            Label(L10n.string("Restore"), systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        Button { exportSnapshot(snap) } label: {
                            Label(L10n.string("Export…"), systemImage: "square.and.arrow.up")
                        }
                        .controlSize(.small)
                        Button(role: .destructive) { toDelete = snap } label: {
                            Label(L10n.string("Delete"), systemImage: "trash")
                        }
                        .controlSize(.small)
                    }
                }
                Text(snap.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metaLine(_ snap: Snapshot) -> String {
        var parts = [
            snap.createdAt.formatted(date: .abbreviated, time: .shortened),
            L10n.formulaeCount(snap.counts.formulae),
            L10n.casksCount(snap.counts.casks),
        ]
        if snap.counts.masApps > 0 {
            let n = snap.counts.masApps
            parts.append(L10n.isRussian
                         ? "\(n) \(L10n.ruPlural(n, one: "приложение MAS", few: "приложения MAS", many: "приложений MAS"))"
                         : "\(n) MAS apps")
        }
        return parts.joined(separator: " · ")
    }

    // New-snapshot sheet.
    private var newSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("New Snapshot")).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Name")).font(.caption).foregroundStyle(.secondary)
                TextField(L10n.isRussian ? "Имя снимка" : "snapshot-name", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
            }
            Text(L10n.string("Stored in ~/Library/Application Support/brew-browser/brewfiles/"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { showNewSheet = false }.keyboardShortcut(.cancelAction)
                Button(L10n.string("Create"), action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Actions

    private func defaultLabel() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "snapshot-\(f.string(from: Date()))"
    }

    private func create() {
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        showNewSheet = false
        Task { await model.dumpSnapshot(label: label) }
    }

    @MainActor
    private func exportSnapshot(_ snap: Snapshot) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(snap.label).Brewfile"
        panel.canCreateDirectories = true
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await model.exportSnapshot(snap, to: url) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    @MainActor
    private func importSnapshot() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await model.importSnapshot(from: url) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    // Binding helpers for the confirmation dialogs / alert.
    private var restoreBinding: Binding<Bool> {
        Binding(get: { toRestore != nil }, set: { if !$0 { toRestore = nil } })
    }
    private var deleteBinding: Binding<Bool> {
        Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })
    }
    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

#if DEBUG
#Preview("Snapshots") {
    SnapshotsView(model: .preview())
        .frame(width: 820, height: 560)
}
#endif
