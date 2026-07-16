import SwiftUI
import Charts

/// Trending — the install leaderboard from Homebrew's published analytics
/// (always-on), with an optional velocity column + inline sparkline when
/// Enhanced Trending is enabled. Stock `Table` + centered window segmented
/// control, reusing the Library/Discover pattern + shared `PackageIcon` +
/// `.inspector` detail.
struct TrendingView: View {
    @Bindable var model: AppModel

    @State private var selectedID: TrendingRow.ID?

    var body: some View {
        Group {
            if model.trendingLoading && model.trendingEntries.isEmpty {
                ProgressView(L10n.string("Fetching install counts from formulae.brew.sh…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    windowBar
                    Divider()
                    table.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .task { await model.loadTrending() }
        .onChange(of: model.showDetail) { _, shown in
            if !shown { selectedID = nil }
        }
    }

    // Centered time-window segmented control (matches Library/Discover slot),
    // with an "Updated …" freshness label + Refresh button trailing (Tauri
    // parity). The picker is centered via overlay so the trailing cluster
    // doesn't shift it off-center.
    private var windowBar: some View {
        Picker(L10n.isRussian ? "Период" : "Window", selection: Binding(
            get: { model.trendingWindow },
            set: { w in Task { await model.setTrendingWindow(w) } }
        )) {
            ForEach(TrendingWindow.allCases) { w in
                Text(w.label).tag(w)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(alignment: .trailing) {
            HStack(spacing: 10) {
                if let updated = updatedLabel {
                    Text(updated).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Task { await model.refreshTrending() }
                } label: {
                    // Spinner replaces the arrow while fetching so a click reads
                    // as "working" even when the refresh returns quickly.
                    Label {
                        Text(L10n.string("Refresh"))
                    } icon: {
                        if model.trendingLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .disabled(model.trendingLoading)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// "Updated Ns/m/h ago" from the last fetch timestamp.
    private var updatedLabel: String? {
        guard let at = model.trendingFetchedAt else { return nil }
        let secs = Int(max(0, Date().timeIntervalSince1970 - at))
        let ago = L10n.shortElapsed(seconds: secs)
        return L10n.isRussian ? "Обновлено \(ago) назад" : "Updated \(ago) ago"
    }

    @ViewBuilder
    private var table: some View {
        let rows = model.sortedTrendingRows
        if rows.isEmpty {
            ContentUnavailableView(
                L10n.string("Couldn't load trending"),
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text(model.settings.paranoidMode
                                  ? L10n.string("Offline Mode is on — trending needs formulae.brew.sh.")
                                  : L10n.string("formulae.brew.sh returned no entries."))
            )
        } else {
            // Velocity is ALWAYS shown (computed from analytics, like Tauri).
            // Only the inline sparkline is gated on Enhanced Trending (opt-in
            // zerologic source). Description is AI-gated. Static column sets
            // (conditional TableColumns destabilize NSTableView), so 2 layouts
            // along the description axis.
            if model.settings.aiFeaturesVisible {
                table(rows, sparkline: model.enhancedTrendingOn, desc: true)
            } else {
                table(rows, sparkline: model.enhancedTrendingOn, desc: false)
            }
        }
    }

    /// Sort binding (plain pass-through; the leaderboard default is install-desc,
    /// matching Tauri — velocity is a sortable column, not the default).
    private var sortBinding: Binding<[KeyPathComparator<TrendingRow>]> {
        $model.trendingSort
    }

    @ViewBuilder
    private func table(_ rows: [TrendingRow], sparkline: Bool, desc: Bool) -> some View {
        Table(rows, selection: $selectedID, sortOrder: sortBinding) {
            TableColumn("#", value: \.rank) { r in
                Text("\(r.rank)").foregroundStyle(.secondary).monospacedDigit()
            }.width(min: 32, ideal: 40)

            TableColumn(L10n.string("Name"), value: \.name) { nameCell($0) }.width(min: 130, ideal: 190)

            if desc {
                TableColumn(L10n.string("Description"), value: \.summary) { r in
                    Text(r.summary).foregroundStyle(.secondary).lineLimit(1)
                }.width(min: 140, ideal: 260)
            }

            TableColumn(L10n.string("Version"), value: \.version) { r in
                Text(r.version).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }.width(min: 60, ideal: 90)

            TableColumn(L10n.string("Type"), value: \.kind.rawValue) { KindPill(kind: $0.kind) }.width(min: 56, ideal: 72)

            // Velocity is always shown — computed from the analytics windows.
            TableColumn(L10n.string("Velocity"), value: \.velocityRank) { velocityCell($0) }.width(min: 64, ideal: 84)

            TableColumn(L10n.string("Installs"), value: \.installCount) { r in
                // Stacked: count on top, sparkline (opt-in) beneath (matches Tauri).
                VStack(alignment: .trailing, spacing: 2) {
                    Text(r.installCount, format: .number).monospacedDigit()
                    if sparkline {
                        let pts = Self.trimmedSparkline(r.sparkline)
                        if pts.count > 1 {
                            Chart(Array(pts.enumerated()), id: \.offset) { i, v in
                                LineMark(x: .value("i", i), y: .value("v", v))
                                    .interpolationMethod(.catmullRom)
                            }
                            .chartXAxis(.hidden).chartYAxis(.hidden)
                            .frame(width: 70, height: 16)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 90, ideal: 130)

            TableColumn(L10n.string("Installed"), value: \.installedRank) { r in
                if r.isInstalled {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(L10n.string("Installed"))
                }
            }.width(min: 56, ideal: 72)
        }
        .onChange(of: selectedID, openSelected)
    }

    @ViewBuilder
    private func nameCell(_ row: TrendingRow) -> some View {
        HStack(spacing: 8) {
            PackageIcon(model: model, token: row.token, kind: row.kind, homepage: row.homepage)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.token)
                    if let severity = row.maxSeverity {
                        SeverityDot(severity: severity, count: row.vulnCount)
                    }
                }
                // AI friendly name as a dimmed subtitle (matches Library/Discover
                // + the Tauri Trending layout). Resolved in trendingRows.
                if !row.friendlyName.isEmpty {
                    Text(row.friendlyName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func velocityCell(_ row: TrendingRow) -> some View {
        if let v = row.velocity {
            // Canonical banded rule (matches velocity_index's documented
            // 1.0≈steady, >1.5 surging, <0.7 cooling — shared with Tauri):
            // ≥1.5 → flame, ≤0.7 → snowflake, otherwise neutral (no icon).
            HStack(spacing: 4) {
                if v >= 1.5 {
                    Image(systemName: "flame.fill").foregroundStyle(.orange).font(.caption2)
                } else if v <= 0.7 {
                    Image(systemName: "snowflake").foregroundStyle(.blue).font(.caption2)
                }
                Text(v, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit().font(.caption)
                    .foregroundStyle(v >= 1.5 ? .orange : (v <= 0.7 ? .blue : .secondary))
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// Trim the long flat lead-in of zeros the seed data carries (sparklines
    /// look like [0,0,0,…,13,1597,…]) so the rendered line shows the meaningful
    /// recent activity, not a mostly-empty axis. Keeps a couple of points of
    /// lead for visual context.
    private static func trimmedSparkline(_ values: [Double]) -> [Double] {
        guard let firstNonZero = values.firstIndex(where: { $0 != 0 }) else { return [] }
        let start = max(0, firstNonZero - 2)
        return Array(values[start...])
    }

    private func openSelected() {
        guard let id = selectedID,
              let row = model.sortedTrendingRows.first(where: { $0.id == id }) else { return }
        model.openDetail(InstalledPackage(name: row.token, version: row.version, kind: row.kind))
    }
}

#if DEBUG
#Preview("Trending") {
    TrendingView(model: .preview())
        .frame(width: 820, height: 560)
}
#endif
