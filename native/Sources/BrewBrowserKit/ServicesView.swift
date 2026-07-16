import SwiftUI

/// Services — start/stop/restart Homebrew background services, parity with the
/// Tauri `Services.svelte`. Stock SwiftUI: a header tally + Refresh, a sortable
/// `Table` (Name · Status · User · Actions), and per-row start/stop/restart.
///
/// Action UX is "hybrid": a quiet per-row spinner on the happy path, with
/// failures surfaced as a failed Activity job in the drawer (see
/// `AppModel.performServiceAction`).
struct ServicesView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { if !model.servicesLoaded { await model.loadServices() } }
    }

    // MARK: - Header

    private var runningCount: Int { model.services.filter { $0.status.isRunning }.count }

    private var headerBar: some View {
        HStack(spacing: 10) {
            if !model.services.isEmpty {
                Text(L10n.servicesSummary(running: runningCount, total: model.services.count))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.loadServices() } } label: {
                // Spinner replaces the arrow while refreshing (matches Trending).
                Label {
                    Text(L10n.string("action.refresh"))
                } icon: {
                    if model.servicesLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .disabled(model.servicesLoading)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.servicesLoading && model.services.isEmpty {
            ProgressView(L10n.string("services.loading"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = model.servicesError, model.services.isEmpty {
            ContentUnavailableView {
                Label(L10n.string("services.loadFailed"), systemImage: "gearshape.2")
            } description: {
                Text(err)
            } actions: {
                Button(L10n.string("action.retry")) { Task { await model.loadServices() } }
            }
        } else if model.services.isEmpty {
            ContentUnavailableView {
                Label(L10n.string("services.empty.title"), systemImage: "gearshape.2")
            } description: {
                Text(L10n.string("services.empty.body"))
            }
        } else {
            servicesTable
        }
    }

    private var servicesTable: some View {
        Table(model.sortedServices) {
            TableColumn(L10n.string("table.name")) { svc in nameCell(svc) }
                .width(min: 140, ideal: 240)
            TableColumn(L10n.string("table.status")) { svc in ServiceStatusPill(status: svc.status) }
                .width(min: 92, ideal: 112)
            TableColumn(L10n.string("table.user")) { svc in
                Text(svc.user ?? "—").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 130)
            TableColumn(L10n.string("table.actions")) { svc in actionCell(svc) }
                .width(min: 108, ideal: 124)
        }
    }

    // MARK: - Cells

    private func nameCell(_ svc: Service) -> some View {
        HStack(spacing: 6) {
            Button {
                // Services are formulae; open the detail inspector (loadDetail
                // resolves the package info).
                model.openDetail(InstalledPackage(name: svc.name, version: "—", kind: .formula))
            } label: {
                Text(svc.name).lineLimit(1)
            }
            .buttonStyle(.link)
            // Per-row severity dot — services are formulae, so look the name up
            // in the install-wide scan rollup (no-ops when scanning is off or the
            // formula is clean / unscanned). Same dot as Library/Discover/Trending.
            if let vuln = model.vulnSummary(for: svc.name), let severity = vuln.maxSeverity {
                SeverityDot(severity: severity, count: vuln.total)
            }
        }
    }

    @ViewBuilder
    private func actionCell(_ svc: Service) -> some View {
        if model.servicePending.contains(svc.name) {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: 8) {
                Button { act(.start, svc) } label: { Image(systemName: "play.fill") }
                    .disabled(svc.status == .started)
                    .help(svc.status == .started ? L10n.string("services.alreadyRunning") : L10n.string("services.start"))
                Button { act(.stop, svc) } label: { Image(systemName: "stop.fill") }
                    .disabled(svc.status == .stopped || svc.status == .notLoaded)
                    .help(svc.status == .stopped || svc.status == .notLoaded ? L10n.string("services.notRunning") : L10n.string("services.stop"))
                Button { act(.restart, svc) } label: { Image(systemName: "arrow.clockwise") }
                    .help(L10n.string("services.restart"))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private func act(_ verb: ServiceVerb, _ svc: Service) {
        Task { await model.performServiceAction(verb, name: svc.name) }
    }
}

/// Colored status capsule for a brew service, mirroring the Tauri status pills
/// (started → green "running", scheduled → orange, error → red, the rest gray).
struct ServiceStatusPill: View {
    let status: Service.Status

    var body: some View {
        Text(label)
            .font(.caption).fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .started: return L10n.string("services.status.running")
        case .stopped: return L10n.string("services.status.stopped")
        case .notLoaded: return L10n.string("services.status.notLoaded")
        case .error: return L10n.string("services.status.error")
        case .scheduled: return L10n.string("services.status.scheduled")
        case .unknown: return L10n.string("services.status.unknown")
        }
    }

    private var color: Color {
        switch status {
        case .started: return .green
        case .scheduled: return .orange
        case .error: return .red
        case .stopped, .notLoaded, .unknown: return .secondary
        }
    }
}

#if DEBUG
#Preview("Services") {
    ServicesView(model: .preview())
        .frame(width: 820, height: 560)
}
#endif
