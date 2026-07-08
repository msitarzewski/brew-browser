import SwiftUI
import Charts

/// The package detail inspector — full Tauri-parity port of `PackageDetail.svelte`.
/// Stock SwiftUI only. Sections render in the same order as the Tauri panel and
/// gate on the same settings (AI features, vuln scanning, GitHub, enhanced
/// trending). Network/scan sections show only when their data is present or
/// their feature is enabled.
struct PackageDetailView: View {
    @Bindable var model: AppModel
    let pkg: InstalledPackage

    @State private var confirmUninstall = false
    @State private var showIssueSheet = false
    @State private var issueTitle = ""
    @State private var issueBody = ""

    private var info: PackageInfo? { model.detailInfo }
    private var enrichment: EnrichmentEntry? { model.detailEnrichment }

    /// Display title: enriched friendly name when available, else the token.
    private var title: String { enrichment?.friendlyName ?? pkg.name }

    /// Installed = the package is in the live installed list (from `brew list`,
    /// authoritative + no cache lag) OR brew info reports an installed version.
    /// `brew info --json` caches metadata, so right after an install it can
    /// still say installed:null — the installed list reflects reality first, so
    /// it's the primary signal here. Drives the footer's Install/Uninstall.
    private var isInstalled: Bool {
        if installedPackage != nil {
            return true
        }
        return info?.installedVersion != nil
    }

    private var installedPackage: InstalledPackage? {
        model.installedPackageMatching(token: pkg.name, kind: pkg.kind)
    }

    private var installedOnRequest: Bool {
        installedPackage?.installedOnRequest ?? pkg.installedOnRequest
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Close box pinned top-right; the icon + title center beneath it.
                HStack {
                    Spacer()
                    Button {
                        model.closeDetail()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("Close"))
                }
                .padding(.bottom, -8)  // tuck the title block up under the ✕ row

                // Centered icon (casks) + title + kind pill — the app's identity
                // at the top of the inspector, above the meta table.
                VStack(spacing: 8) {
                    DetailIcon(model: model, token: pkg.name, kind: pkg.kind,
                               homepage: info?.homepage ?? "")
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    KindPill(kind: pkg.kind)
                }
                .frame(maxWidth: .infinity)

                if model.detailLoading && info == nil {
                    ProgressView(L10n.isRussian ? "Загружаем \(pkg.name)…" : "Loading \(pkg.name)…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let err = model.detailError, info == nil {
                    ContentUnavailableView(L10n.isRussian ? "Не удалось загрузить \(pkg.name)" : "Couldn't load \(pkg.name)",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(err))
                } else {
                    metaCard
                    if let summary = enrichment?.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Spacer()
                                wrongButton(.summary, currentValue: summary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: .rect(cornerRadius: 10))
                    }
                    if let desc = info?.desc, !desc.isEmpty {
                        Text(desc).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let hp = info?.homepage, let url = URL(string: hp) {
                        Link(destination: url) {
                            Label(hp, systemImage: "safari").lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if !model.detailCategories.isEmpty { categoriesRow }
                    if let tags = enrichment?.tags, !tags.isEmpty { tagsRow(tags) }

                    deprecationCard
                    if AppSettings.shared.vulnerabilityScanningAllowed { securityCard }
                    serviceCard
                    if model.detailTrend != nil { trendCard }
                    if let useCases = enrichment?.useCases, !useCases.isEmpty { useCasesCard(useCases) }
                    if let similar = enrichment?.similar, !similar.isEmpty { similarCard(similar) }
                    if AppSettings.shared.githubAllowed, model.detailRepoStats != nil { githubCard }
                    if let caveats = info?.caveats, !caveats.isEmpty { caveatsCard(caveats) }
                    dependenciesSection
                    dependentsSection
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { footer }
        // Device-flow sign-in sheet — shown while authorizing with GitHub.
        .sheet(isPresented: Binding(
            get: { model.deviceFlow != nil },
            set: { if !$0 { model.cancelGitHubSignIn() } }
        )) {
            if let flow = model.deviceFlow { deviceFlowSheet(flow) }
        }
        // File-issue sheet.
        .sheet(isPresented: $showIssueSheet) { issueSheet }
    }

    // MARK: github sheets

    private func deviceFlowSheet(_ flow: DeviceFlowStart) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key").font(.largeTitle).foregroundStyle(.secondary)
            Text(L10n.string("Sign in to GitHub")).font(.title2.weight(.semibold))
            Text(L10n.string("Your browser opened to GitHub's device page. Enter this code (it's copied to your clipboard):"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text(flow.userCode)
                .font(.system(.title, design: .monospaced).weight(.bold))
                .textSelection(.enabled)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.quaternary, in: .rect(cornerRadius: 8))
            ProgressView(L10n.string("Waiting for authorization…")).controlSize(.small)
            Button(L10n.string("Cancel")) { model.cancelGitHubSignIn() }
            if let err = model.githubSignInError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(28)
        .frame(width: 360)
    }

    private var issueSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.isRussian ? "Сообщить о проблеме для \(pkg.name)" : "File an issue for \(pkg.name)").font(.headline)
            TextField(L10n.string("Title"), text: $issueTitle)
            TextField(L10n.string("Description"), text: $issueBody, axis: .vertical)
                .lineLimit(5...10)
            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { showIssueSheet = false }
                Button(L10n.string("Submit")) {
                    let t = issueTitle, b = issueBody
                    showIssueSheet = false
                    Task {
                        if let url = await model.fileIssue(title: t, body: b),
                           let u = URL(string: url) { NSWorkspace.shared.open(u) }
                    }
                    issueTitle = ""; issueBody = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(issueTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: meta

    private var metaCard: some View {
        VStack(spacing: 0) {
            metaRow(L10n.string("Token"), pkg.name, mono: true)
            Divider()
            HStack {
                Text(L10n.string("Installed")).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Text(info?.installedVersion ?? L10n.string("Not installed"))
                    .textSelection(.enabled)
                // Dependency indicator: a formula installed only as a dependency
                // (not on request) — mirrors the Tauri detail badge. Casks are
                // always on-request so never show this. Feature #3.
                if isInstalled, pkg.kind == .formula, !installedOnRequest {
                    Text(L10n.string("Dependency"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: .capsule)
                        .help(L10n.string("Installed as a dependency, not requested directly"))
                }
                Spacer()
            }
            .padding(.vertical, 6)
            Divider()
            HStack {
                Text(L10n.string("Latest")).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Text(info?.stableVersion ?? "—").monospaced()
                if info?.isOutdated == true {
                    Text(L10n.string("Upgrade available"))
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            if let lic = info?.license {
                Divider(); metaRow(L10n.string("License"), lic)
            }
            if let tap = info?.tap {
                Divider(); metaRow(L10n.string("Tap"), tap, mono: true)
            }
            // On-disk size of the installed keg (feature #4). Rendered only when
            // the package is installed and du succeeded — nil → no row (never a
            // fabricated "0 B"). Lazily computed in BrewService.info().
            if let bytes = info?.installedSizeBytes {
                Divider(); metaRow(L10n.string("Size"), Self.human(bytes))
            }
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: 10))
    }

    /// Human byte formatting for the Size row — matches the Tauri Dashboard
    /// `fmtBytes` thresholds EXACTLY for cross-shell parity: B (<1 KiB),
    /// KB (1 decimal), MB (1 decimal), GB (2 decimals). Distinct from
    /// `StorageCard.human`, which floors to whole MB and skips KB/B — the detail
    /// panel needs the finer granularity (parity contract #4).
    static func human(_ bytes: Int64) -> String {
        let b = Double(bytes)
        let kib = 1024.0, mib = 1_048_576.0, gib = 1_073_741_824.0
        if b >= gib { return String(format: "%.2f GB", b / gib) }
        if b >= mib { return String(format: "%.1f MB", b / mib) }
        if b >= kib { return String(format: "%.1f KB", b / kib) }
        return "\(bytes) B"
    }

    private func metaRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).font(mono ? .body.monospaced() : .body)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var categoriesRow: some View {
	        VStack(alignment: .leading, spacing: 4) {
	            FlowRow(spacing: 6) {
	                ForEach(model.detailCategories, id: \.self) { label in
	                    Chip(text: L10n.display(label))
	                }
	            }
            HStack {
                Spacer()
                wrongButton(.categories, currentValue: model.detailCategories.joined(separator: ", "))
            }
        }
    }

    private func tagsRow(_ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowRow(spacing: 6) {
                ForEach(tags, id: \.self) { Chip(text: $0) }
            }
            HStack {
                Spacer()
                wrongButton(.tags, currentValue: tags.joined(separator: ", "))
            }
        }
    }

    // MARK: enrichment correction ("Wrong?")

    /// Small, secondary "Wrong?" affordance next to an AI-enriched field. Opens a
    /// pre-filled brew-browser GitHub issue (token + field + current value) via
    /// `ReportIssue` — the deeplink correction path. Enrichment corrections go to
    /// the brew-browser repo (not the package's own repo), so this reuses the
    /// job/enrichment issue builder rather than the package File-issue sheet.
    /// (i) InfoButton for an enriched field — a popover explaining how the field
    /// was generated + a "Report an issue on GitHub" button. Replaces the old
    /// "Wrong?" link; mirrors the Tauri `InfoButton`.
    private func wrongButton(_ field: ReportIssue.EnrichmentField, currentValue: String) -> some View {
        InfoButton(
            title: field.infoTitle,
            message: field.infoBody,
            label: field.infoTitle
        ) {
            ReportIssue.openEnrichmentCorrection(token: pkg.name, field: field, currentValue: currentValue)
        }
    }

    // MARK: security

    // MARK: deprecation

    /// Deprecation / disabled notice — renders before the Security card, mirroring
    /// the Tauri PackageDetail notice block. Shows nothing when the package is
    /// clean (never a placeholder). The status prefers `brew info` (the only
    /// source of the "use X instead" replacement) and falls back to the offline
    /// catalog baseline while info loads. `disabled` wins over `deprecated`
    /// (danger vs. warning tone). Reason/date strings are rendered verbatim. The
    /// replacement, when present, is a tappable chip that re-opens the inspector
    /// on that token (brew info re-fetches; an unknown token hits the existing
    /// detail error path). Feature #2.
    @ViewBuilder private var deprecationCard: some View {
        let status = model.detailDeprecation
        if let badge = status.badge {
            let isDisabled = badge == .disabled
            let tone: Color = isDisabled ? .red : .orange
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string(isDisabled ? "detail.deprecation.disabled.body" : "detail.deprecation.deprecated.body"))
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let reason = status.activeReason, !reason.isEmpty {
                        Text(reason)
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    if let date = status.activeDate, !date.isEmpty {
                        Text(String(format: L10n.string(isDisabled ? "detail.deprecation.disabledDate.format" : "detail.deprecation.deprecatedDate.format"), date))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let replacement = status.activeReplacement, !replacement.isEmpty {
                        HStack(spacing: 6) {
                            Text(L10n.string("detail.deprecation.useInstead")).font(.callout).foregroundStyle(.secondary)
                            Button {
                                // Most replacements share the deprecated package's
                                // kind (formula→formula, cask→cask); openDetail
                                // re-fetches brew info and the bare-name retry +
                                // error path cover a kind/tap mismatch.
                                model.openDetail(InstalledPackage(name: replacement, version: "—", kind: pkg.kind))
                            } label: {
                                Text(replacement).font(.callout)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            } label: {
                Label(badge.label, systemImage: isDisabled ? "xmark.octagon" : "exclamationmark.triangle")
                    .foregroundStyle(tone)
            }
        }
    }

    @ViewBuilder private var securityCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if !model.brewVulnsInstalled {
                Text(L10n.string("Install `brew vulns` to scan this package for known vulnerabilities."))
                        .font(.callout).foregroundStyle(.secondary)
                } else if model.detailVulnsLoading {
                    ProgressView(L10n.string("Scanning all packages…"))
                } else if !model.detailVulnsScanned {
                    // Never scanned — hazard tone; don't imply safety unverified.
                    Label {
                        Text(L10n.string("detail.security.notScanned.detail"))
                            .font(.callout).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button(L10n.string("Scan all packages")) { Task { await model.scanDetailVulns() } }
                } else if model.detailVulns.isEmpty {
                    // "Clean" is only a confident green when freshly scanned this
                    // session; a cached/stale clean is a caution, not an all-clear.
                    if model.vulnScannedThisSession {
                        Label(L10n.string("No known vulnerabilities"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label(L10n.string("detail.security.cleanStale"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    rescanRow
                } else {
                    // No "Upgrade to fix" here — it duplicates the footer's
                    // Upgrade CTA (a fixable advisory means the package is
                    // outdated, so the footer already offers Upgrade).
                    ForEach(model.detailVulns) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                // Clickable advisory id → canonical advisory page
                                // (NVD / osv.dev / GitHub advisories). Falls back
                                // to a plain id when there's no resolvable URL.
                                if !v.rawId.isEmpty, let url = model.advisoryURL(for: v) {
                                    Button {
                                        NSWorkspace.shared.open(url)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Text(v.rawId).font(.callout.monospaced())
                                            Image(systemName: "arrow.up.right.square").font(.caption2)
                                        }
                                    }
                                    .buttonStyle(.link)
                                    .help(String(format: L10n.string("detail.security.openAdvisory.format"), url.absoluteString))
                                } else {
                                    Text(v.rawId.isEmpty ? L10n.string("Advisory") : v.rawId)
                                        .font(.callout.monospaced())
                                }
                                SeverityPill(severity: v.severity)
                                Spacer()
                                if let fixed = v.fixedIn {
                                    Text(String(format: L10n.string("detail.security.patchedIn.format"), fixed)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if !v.summary.isEmpty {
                                Text(v.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    rescanRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            Label(L10n.string("Security"), systemImage: "shield")
        }
    }

    /// "Re-scan all" — these results come from the cached install-wide scan, so
    /// re-checking is a full system re-scan (not just this package). The caption
    /// makes that explicit.
    @ViewBuilder private var rescanRow: some View {
        HStack(spacing: 8) {
            Button(L10n.string("Re-scan all")) { Task { await model.scanDetailVulns() } }
                .controlSize(.small)
            if let at = model.vulnLastScannedAt {
                Text(String(format: L10n.string("detail.security.lastScan.format"), at.formatted(.relative(presentation: .named))))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 2)
        .help(L10n.string("detail.security.rescanHelp"))
    }

    // MARK: service

    /// Background-service controls for an installed formula that registers one,
    /// mirroring the Tauri PackageDetail service card. Only renders when the
    /// services list (loaded lazily on detail open) has a matching entry.
    @ViewBuilder private var serviceCard: some View {
        if pkg.kind == .formula, let svc = model.service(for: pkg.name) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ServiceStatusPill(status: svc.status)
                        Spacer()
                        if let user = svc.user {
                            Text(L10n.isRussian ? "пользователь: \(user)" : "user: \(user)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.servicePending.contains(svc.name) {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 8) {
                            Button(L10n.string("Start")) { Task { await model.performServiceAction(.start, name: svc.name) } }
                                .disabled(svc.status == .started)
                            Button(L10n.string("Stop")) { Task { await model.performServiceAction(.stop, name: svc.name) } }
                                .disabled(svc.status == .stopped || svc.status == .notLoaded)
                            Button(L10n.string("Restart")) { Task { await model.performServiceAction(.restart, name: svc.name) } }
                        }
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            } label: {
                Label(L10n.string("Service"), systemImage: "gearshape.2")
            }
        }
    }

    // MARK: trend

    @ViewBuilder private var trendCard: some View {
        if let series = model.detailTrend {
            GroupBox {
                let values = sparkValues(series)
                if values.count > 1 {
                    Chart(Array(values.enumerated()), id: \.offset) { i, v in
                        LineMark(x: .value("i", i), y: .value("installs", v))
                            .interpolationMethod(.catmullRom)
                    }
                    .frame(height: 80)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .padding(.top, 4)
                } else {
                    Text(L10n.string("Not enough data yet")).font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                Label(L10n.string("Install trend"), systemImage: "chart.line.uptrend.xyaxis")
            }
        }
    }

    private func sparkValues(_ s: TrendingHistorySeries) -> [Double] {
        s.points.compactMap { p in
            if let e = p.estimatedDailyInstalls { return Double(e) }
            if let c = p.count30d { return Double(c) }
            return nil
        }
    }

    private func useCasesCard(_ cases: [String]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(cases, id: \.self) { c in
                    Label(c, systemImage: "checkmark.circle").font(.callout)
                }
                HStack {
                    Spacer()
                    wrongButton(.useCases, currentValue: cases.joined(separator: "\n"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            Label(L10n.string("Why install this?"), systemImage: "lightbulb")
        }
    }

    private func similarCard(_ similar: [String]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                FlowRow(spacing: 6) {
                    ForEach(similar, id: \.self) { name in
                        Button(name) { model.openDetail(InstalledPackage(name: name, version: "—", kind: .formula)) }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                    }
                }
                HStack {
                    Spacer()
                    wrongButton(.similar, currentValue: similar.joined(separator: ", "))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            Label(L10n.string("Similar packages"), systemImage: "square.stack.3d.up")
        }
    }

    // MARK: github

    @ViewBuilder private var githubCard: some View {
        if let stats = model.detailRepoStats {
            // Toggle states: filled/active when starred or watching, calling the
            // unstar/unwatch path when already on. Mirrors `PackageDetail.svelte`.
            let starred = model.githubSignedIn && model.detailStarred == true
            let watching = model.githubSignedIn && model.detailWatching == true
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Label("\(stats.stars)", systemImage: "star")
                        Label("\(stats.forks)", systemImage: "tuningfork")
                        if let tag = stats.lastReleaseTag {
                            if let date = stats.lastReleaseDate {
                                Label("\(tag) (\(relativeISO(date)))", systemImage: "tag")
                            } else {
                                Label(tag, systemImage: "tag")
                            }
                        }
                        Spacer()
                    }
                    .font(.callout)

                    // Archived-repo warning — likely unmaintained.
                    if stats.archived {
                        Label {
                            Text(L10n.isRussian
                                 ? "Архивирован\(stats.archivedAt.map { " \(relativeISO($0))" } ?? "") — вероятно, больше не поддерживается."
                                 : "Archived\(stats.archivedAt.map { " \(relativeISO($0))" } ?? "") — likely unmaintained.")
                        } icon: {
                            Image(systemName: "archivebox").foregroundStyle(.orange)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    // License-mismatch warning — brew license != GitHub SPDX.
                    if let spdx = stats.licenseSpdx, let brewLic = info?.license, spdx != brewLic {
                        Label {
                            if L10n.isRussian {
                                Text("Лицензии не совпадают — brew: \(Text(brewLic).monospaced()), GitHub: \(Text(spdx).monospaced())")
                            } else {
                                Text("License mismatch — brew: \(Text(brewLic).monospaced()), GitHub: \(Text(spdx).monospaced())")
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(L10n.isRussian ? "brew сообщает: \(brewLic) · GitHub сообщает: \(spdx)" : "brew reports: \(brewLic) · GitHub reports: \(spdx)")
                    }

                    // Star / Watch / File issue — each routes through the model,
                    // which prompts device-flow sign-in if signed out (no more
                    // silent no-op). Star + Watch are toggles: the label and the
                    // filled glyph reflect the current state. Mirrors the Tauri
                    // action set.
                    HStack(spacing: 8) {
                        Button {
                            Task { await model.toggleStar() }
                        } label: {
                            Label(starred ? L10n.string("Starred") : L10n.string("Star"),
                                  systemImage: starred ? "star.fill" : "star")
                        }
                        .help(!model.githubSignedIn
                              ? L10n.string("Sign in to GitHub to star this repository")
                              : starred ? L10n.string("Unstar this repository") : L10n.string("Star this repository"))
                        Button {
                            Task { await model.toggleWatch() }
                        } label: {
                            Label(watching ? L10n.string("Watching") : L10n.string("Watch"),
                                  systemImage: watching ? "eye.fill" : "eye")
                        }
                        .help(!model.githubSignedIn
                              ? L10n.string("Sign in to GitHub to watch this repository")
                              : watching ? L10n.string("Stop watching") : L10n.string("Watch for activity"))
                        Button {
                            showIssueSheet = true
                        } label: {
                            Label(L10n.string("File issue"), systemImage: "exclamationmark.bubble")
                        }
                        Spacer()
                    }
                    .controlSize(.small)

                    if !model.githubSignedIn {
                        Text(L10n.string("Sign in to GitHub happens on first action."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            } label: {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
    }

    /// Relative-time label for an ISO 8601 timestamp ("2 months ago"). Mirrors
    /// the Tauri `fmtRelative`. Falls back to the raw string if it won't parse.
    private func relativeISO(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private func caveatsCard(_ caveats: String) -> some View {
        GroupBox {
            Text(caveats)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        } label: {
            Label(L10n.string("Caveats"), systemImage: "exclamationmark.bubble")
        }
    }

    @ViewBuilder private var dependenciesSection: some View {
        if let info, !info.dependencies.isEmpty {
            DisclosureGroup(L10n.isRussian ? "Зависимости (\(info.dependencies.count))" : "Dependencies (\(info.dependencies.count))") {
                FlowRow(spacing: 6) {
                    ForEach(info.dependencies, id: \.self) { Chip(text: $0) }
                }
            }
        }
        if let info, !info.conflictsWith.isEmpty {
            DisclosureGroup(L10n.isRussian ? "Конфликтует с (\(info.conflictsWith.count))" : "Conflicts with (\(info.conflictsWith.count))") {
                FlowRow(spacing: 6) {
                    ForEach(info.conflictsWith, id: \.self) { Chip(text: $0) }
                }
            }
        }
    }

    /// "Required by" — catalog packages that depend on this one (reverse edges of
    /// the dependency graph, inverted from the same bundled catalog). Buttons
    /// navigate to the dependent's detail, exactly like the Similar-packages
    /// pills. Honest empty state: the whole section is omitted when nothing in
    /// the catalog depends on this package. A DisclosureGroup keeps high-fan-in
    /// targets (e.g. `openssl@3` with thousands of dependents) collapsible,
    /// mirroring the Dependencies disclosure.
    @ViewBuilder private var dependentsSection: some View {
        let dependents = model.detailDependents
        if !dependents.isEmpty {
            DisclosureGroup(L10n.isRussian ? "Зависимые пакеты (\(dependents.count))" : "Required by (\(dependents.count))") {
                FlowRow(spacing: 6) {
                    ForEach(dependents) { dep in
                        Button {
                            model.openDetail(InstalledPackage(name: dep.name, version: "—", kind: dep.kind))
                        } label: {
                            HStack(spacing: 4) {
                                Text(dep.name)
                                if dep.edge != .required {
                                    Text(edgeLabel(dep.edge))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else if dep.kind == .cask {
                                    Image(systemName: "shippingbox").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: .capsule)
                    }
                }
            }
        }
    }

    private func edgeLabel(_ edge: ReverseDependent.Edge) -> String {
        if !L10n.isRussian { return edge.rawValue }
        switch edge {
        case .required: return "обязательная"
        case .recommended: return "рекомендуемая"
        case .build: return "для сборки"
        case .optional: return "опциональная"
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            if model.actionRunning {
                ProgressView().controlSize(.small)
                Text(L10n.string("Working… (see Activity)")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Footer adapts to install state, driven by the live installed list
            // (`isInstalled`) so it's correct even while `brew info` reloads
            // after an action (info goes nil mid-reload; the list does not).
            // Show buttons once we have either signal — avoids an empty footer
            // during the post-install detail refresh.
            if info != nil || isInstalled {
                if isInstalled {
                    if info?.isOutdated == true {
                        Button {
                            Task { await model.upgradeDetail(greedy: LocalPrefs.shared.greedyUpgrade) }
                        } label: { Label(L10n.string("Upgrade"), systemImage: "arrow.up.circle") }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.actionRunning)
                    }
                    Button(role: .destructive) {
                        confirmUninstall = true
                    } label: { Label(L10n.string("Uninstall"), systemImage: "trash") }
                    .disabled(model.actionRunning)
                } else {
                    Button {
                        Task { await model.installDetail() }
                    } label: { Label(L10n.string("Install"), systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.actionRunning)
                }
            }
        }
        .padding(12)
        .background(.bar)
        .confirmationDialog(L10n.isRussian ? "Удалить \(pkg.name)?" : "Uninstall \(pkg.name)?", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button(L10n.string("Uninstall"), role: .destructive) { Task { await model.uninstallDetail() } }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.isRussian ? "Будет выполнено `brew uninstall \(pkg.name)`." : "This runs `brew uninstall \(pkg.name)`.")
        }
    }
}

/// Severity pill for vulnerability findings.
struct SeverityPill: View {
    let severity: VulnSeverity
    private var color: Color {
        switch severity {
        case .critical, .high: return .red
        case .medium: return .orange
        case .low: return .yellow
        case .unknown: return .gray
        }
    }
    var body: some View {
        Text(L10n.severityTitle(severity))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.2), in: .capsule)
            .foregroundStyle(color)
    }
}

/// Small filled circle colored by max severity — the Library row vulnerability
/// indicator. Mirrors the Tauri PackageRow severity dot (colour wins by max
/// severity; hover tooltip carries the finding count + highest severity). Uses
/// the same severity→colour mapping as ``SeverityPill``.
struct SeverityDot: View {
    let severity: VulnSeverity
    let count: Int

    private var color: Color {
        switch severity {
        case .critical, .high: return .red
        case .medium: return .orange
        case .low: return .yellow
        case .unknown: return .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(L10n.vulnerabilityDotHelp(count: count, severity: severity))
    }
}

/// Small deprecation/disabled badge for a list row — sits next to the name in
/// the Library/Discover name cell, beside the vulnerability `SeverityDot`.
/// `disabled` wins over `deprecated` (the AppModel rows already encode that in
/// `DeprecationStatus.badge`), so this view just renders the resolved kind:
/// "Disabled" in red (the package is gone / about to be removed), "Deprecated"
/// in amber (still installable, but on its way out). Mirrors the Tauri PackageRow
/// deprecation Pill (danger/warning tone). Feature #2.
struct DeprecationBadge: View {
    let kind: DeprecationBadgeKind
    /// Catalog reason, when present — surfaced in the hover tooltip only (the
    /// row stays compact; the full notice lives in the detail panel).
    var reason: String? = nil

    private var color: Color { kind == .disabled ? .red : .orange }

    var body: some View {
        Text(L10n.display(kind.label))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
            .help(tooltip)
    }

    private var tooltip: String {
        let base = kind == .disabled
            ? L10n.string("detail.deprecation.disabled.tooltip")
            : L10n.string("detail.deprecation.deprecated.tooltip")
        if let reason, !reason.isEmpty { return "\(base)\n\(reason)" }
        return base
    }
}

/// Minimal flow layout (wrapping HStack) for pills — stock SwiftUI `Layout`.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Large centered app icon for the detail panel header. Resolves the real icon
/// (Appcasks → Google favicon) for casks via the shared IconService; formulae
/// (CLI tools, no app icon) show a terminal SF Symbol. 64pt to anchor the
/// inspector's identity block above the meta table.
private struct DetailIcon: View {
    @Bindable var model: AppModel
    let token: String
    let kind: InstalledPackage.Kind
    let homepage: String

    var body: some View {
        Group {
            if kind == .cask, let url = model.iconCache[token],
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().interpolation(.high)
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 14))
            } else {
                Image(systemName: kind == .cask ? "app.dashed" : "terminal")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, height: 64)
            }
        }
        .task(id: token) {
            await model.resolveIcon(token: token, kind: kind, homepage: homepage)
        }
    }
}
