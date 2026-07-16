import SwiftUI

/// Bundles (M3) — curated package sets in the app's canonical list form: a stock
/// `Table` whose selection drives the shared right-side `.inspector`
/// (`BundleDetailView`), exactly like Library and Trending. Each row shows the
/// bundle's icon + name + tagline, its package makeup, and a capability-aware
/// readiness pill. Nothing is selected on entry and the inspector stays closed
/// until the user picks a row (matches Library — no auto-select).
public struct BundlesView: View {
    @Bindable var model: AppModel

    /// The table's selection — the bundle `id`. Mirrors the inspector's open
    /// bundle so the highlighted row tracks the detail panel.
    @State private var selectedID: BrewBundle.ID?

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Group {
            if model.bundles.isEmpty {
                ContentUnavailableView(
                    L10n.string("bundles.empty.native.title"),
                    systemImage: "square.stack.3d.up",
                    description: Text(L10n.string("bundles.empty.native.body"))
                )
            } else {
                table
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Keep the table highlight in sync with the inspector: if detail is
        // closed elsewhere (⊗ box / section change), clear the row selection too.
        .onChange(of: model.showDetail) { _, shown in
            if !shown { selectedID = nil }
        }
    }

    // Stock sortable `Table` — single fixed column set (bundles carry no sort
    // order), selection bound to the shared inspector via `openSelected`.
    private var table: some View {
        Table(model.bundles, selection: $selectedID) {
            TableColumn(L10n.string("table.name")) { bundle in
                HStack(spacing: 8) {
                    Image(systemName: bundleSymbol(bundle.icon))
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bundle.name).font(.headline)
                        Text(bundle.tagline)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }.width(min: 220, ideal: 300)

            TableColumn(L10n.string("bundles.header.packages")) { bundle in
                Text(packageSummary(bundle))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }.width(min: 110, ideal: 150)

            TableColumn(L10n.string("bundles.header.readiness")) { bundle in
                ReadinessPill(readiness: model.readiness(for: bundle))
            }.width(min: 120, ideal: 150)
        }
        .onChange(of: selectedID, openSelected)
    }

    private func openSelected() {
        guard let id = selectedID,
              let bundle = model.bundles.first(where: { $0.id == id }) else { return }
        model.openBundleDetail(bundle)
    }
}

// MARK: - Shared readiness UI

/// A small capsule tinted by the readiness verdict, with the reason as its
/// tooltip. Shared by the card and the detail header.
struct ReadinessPill: View {
    let readiness: Readiness
    var body: some View {
        Label(readiness.verdict.pillLabel, systemImage: readiness.verdict.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(readiness.verdict.tone)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(readiness.verdict.tone.opacity(0.15), in: .capsule)
            .help(L10n.readinessReason(readiness.reason))
    }
}

extension ReadinessVerdict {
    /// User-facing pill label. Never a hard block — "Not recommended" is advisory.
    var pillLabel: String {
        switch self {
        case .ready:    return L10n.string("readiness.ready")
        case .marginal: return L10n.string("readiness.marginal")
        case .blocked:  return L10n.string("readiness.blocked")
        }
    }

    var tone: Color {
        switch self {
        case .ready:    return .green
        case .marginal: return .orange
        case .blocked:  return .red
        }
    }

    var symbol: String {
        switch self {
        case .ready:    return "checkmark.circle.fill"
        case .marginal: return "exclamationmark.triangle.fill"
        case .blocked:  return "xmark.octagon.fill"
        }
    }
}

// MARK: - Helpers

/// Map a recipe `icon` token to an SF Symbol (all system symbols, no assets).
/// Unknown/nil tokens fall back to the section glyph.
func bundleSymbol(_ icon: String?) -> String {
    switch icon {
    case "database":     return "cylinder.split.1x2"
    case "palette":      return "paintpalette"
    case "image":        return "photo"
    case "brain":        return "brain"
    case "clapperboard": return "film"
    case "code":         return "chevron.left.forwardslash.chevron.right"
    case "agentic":      return "sparkles"
    case "server":       return "server.rack"
    default:             return "square.stack.3d.up"
    }
}

/// "N formulae · M casks" summary for a bundle's package makeup (omits a zero
/// side; singular/plural aware).
func packageSummary(_ bundle: BrewBundle) -> String {
    let formulae = bundle.packages.filter { $0.kind != "cask" }.count
    let casks    = bundle.packages.filter { $0.kind == "cask" }.count
    return L10n.bundlePackageSummary(formulae: formulae, casks: casks)
}
