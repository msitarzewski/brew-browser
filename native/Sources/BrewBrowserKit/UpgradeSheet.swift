import SwiftUI

/// Curated multi-select upgrade sheet. Presented from the Dashboard Updates
/// card's "Choose…" button. Lists every outdated package with a checkbox,
/// name, kind pill, and current → target version. Pinned formulae are
/// checkbox-disabled AND excluded from selection (brew refuses to upgrade
/// them anyway). On submit, fires ONE `brew upgrade <pkg1> <pkg2> …` via the
/// existing `startJob` Activity pipeline.
///
/// Faithful port of the Tauri `UpgradeModal.svelte`. Selection contract,
/// verbatim from that file:
///   - All non-pinned packages start checked (matches "Upgrade all").
///   - Pinned packages start unchecked AND disabled.
///   - "Select all" / "Deselect all" toggles ALL non-pinned rows; pinned
///     stays excluded regardless.
///   - Submit shows the live selected count and is disabled at zero.
struct UpgradeSheet: View {
    @Bindable var model: AppModel
    let onClose: () -> Void

    /// Row key → checked. Pinned rows are never in this map (excluded entirely).
    @State private var selected: [String: Bool] = [:]

    /// All outdated packages, mirroring the Tauri `packages.outdated` order.
    private var rows: [OutdatedPackage] { model.outdated }
    /// The selectable subset (pinned excluded), like Tauri's `upgradablePackages`.
    private var upgradable: [OutdatedPackage] { rows.filter { !$0.pinned } }

    private func rowKey(_ p: OutdatedPackage) -> String { "\(p.name)::\(p.kind.rawValue)" }
    private func isChecked(_ p: OutdatedPackage) -> Bool { selected[rowKey(p)] == true }

    private var selectedCount: Int { selected.values.filter { $0 }.count }
    private var allSelected: Bool { !upgradable.isEmpty && selectedCount == upgradable.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("upgrade.choosePackages")).font(.headline)

            if rows.isEmpty {
                Text(L10n.string("upgrade.noOutdated"))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                // Toolbar: selected count + select-all/deselect-all toggle.
                HStack {
                    Text(L10n.selectedCount(selectedCount, total: upgradable.count))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(allSelected ? L10n.string("action.deselectAll") : L10n.string("action.selectAll")) {
                        if allSelected { deselectAll() } else { selectAll() }
                    }
                    .buttonStyle(.link)
                }

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { p in
                            row(p)
                            if p.id != rows.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button(L10n.string("action.cancel")) { onClose() }
                Button {
                    let names = rows.filter { isChecked($0) }.map(\.name)
                    onClose()
                    Task { await model.upgradeMany(names, greedy: LocalPrefs.shared.greedyUpgrade) }
                } label: {
                    Label(
                        L10n.upgradePackageButton(selectedCount),
                        systemImage: "arrow.up.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Pre-check every non-pinned package whenever the sheet appears.
        .onAppear { selectAll() }
    }

    private func row(_ p: OutdatedPackage) -> some View {
        Button {
            guard !p.pinned else { return }
            selected[rowKey(p)] = !isChecked(p)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isChecked(p) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(p.pinned ? AnyShapeStyle(.tertiary) : (isChecked(p) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)))
                Text(p.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if p.pinned {
                    Text(L10n.string("package.pinned"))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: .capsule)
                        .foregroundStyle(.orange)
                        .help(L10n.string("upgrade.pinned.help"))
                }
                KindPill(kind: p.kind)
                    .frame(width: 84, alignment: .leading)
                Text("\(p.installedVersion) → \(p.currentVersion)")
                    .font(.callout).foregroundStyle(.secondary).monospaced()
                    .frame(width: 180, alignment: .trailing)
            }
            .contentShape(.rect)
            .padding(.vertical, 7).padding(.horizontal, 10)
            .opacity(p.pinned ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(p.pinned)
    }

    private func selectAll() {
        var next: [String: Bool] = [:]
        for p in upgradable { next[rowKey(p)] = true }
        selected = next
    }

    private func deselectAll() {
        var next: [String: Bool] = [:]
        for p in upgradable { next[rowKey(p)] = false }
        selected = next
    }
}

#if DEBUG
#Preview("Upgrade sheet") {
    UpgradeSheet(model: .preview(), onClose: {})
}
#endif
