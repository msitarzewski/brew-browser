import SwiftUI
import AppKit

/// Bundle detail (M3) — rendered in the app's shared right-side `.inspector`
/// (from `ContentView`, keyed on `model.detailBundle`), the same slot Library
/// and Trending use for package detail. Shows the capability verdict + reason,
/// each package with its live installed state, caveats, links, and an "Install
/// all" action that streams into Activity via `AppModel.installBundle(_:)`. A
/// `blocked` verdict gates Install behind a confirmation (never a hard block).
/// Closing is the inspector's job (its ⊗ box → `AppModel.closeDetail()`), so
/// there's no Done button and no fixed frame — the view fills the column.
struct BundleDetailView: View {
    @Bindable var model: AppModel
    let bundle: BrewBundle

    @State private var confirmBlockedInstall = false

    /// Package rows expanded to show their one-line description. Keyed like the
    /// installed check (`pkg.name`+`pkg.kind`); multiple rows may be open at once.
    @State private var expanded: Set<String> = []
    /// Resolved descriptions, cached so re-expanding a row is instant. A present
    /// value is the display string (real desc or the "no description" fallback);
    /// absent means "not fetched yet" → the row shows the loading state.
    @State private var descriptions: [String: String] = [:]
    /// Packages whose single-package Install is in flight. Keyed like the
    /// installed/expansion checks (`pkg.name`+`pkg.kind`); drives the inline
    /// "Installing…" spinner and reverts to the Install button on failure.
    @State private var installing: Set<String> = []

    private var readiness: Readiness { model.readiness(for: bundle) }

    /// Packages not yet installed — the set "Install all" would actually add.
    private var pendingCount: Int {
        bundle.packages.filter { !isInstalled($0) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Intent paragraph (optional) sits at the top, under the header
                    // tagline — the "why" before the mechanics.
                    if let description = bundle.description, !description.isEmpty {
                        Text(description)
                            .font(.body)
                            .lineSpacing(3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    // The header pill is the single readiness indicator; only
                    // surface a body callout when there's an actual concern.
                    bodyVerdict
                    packagesSection
                    // Caveats sit ABOVE the setup checklist so a heavy bundle's
                    // warning (e.g. Image Gen model downloads) is unmissable.
                    if let caveats = bundle.caveats, !caveats.isEmpty {
                        caveatsCard(caveats)
                    }
                    if let setup = bundle.setup, !setup.isEmpty {
                        setupSection(setup)
                    }
                    if let links = bundle.links, !links.isEmpty {
                        linksSection(links)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: bundleSymbol(bundle.icon))
                .font(.largeTitle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(bundle.name).font(.title2.weight(.semibold))
                Text(bundle.tagline).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ReadinessPill(readiness: readiness)
        }
        .padding(20)
    }

    // MARK: - Verdict

    /// Body readiness callout — DEDUPED against the header `ReadinessPill`.
    /// A `.ready` bundle shows nothing here (the header pill is the sole verdict);
    /// `.marginal`/`.blocked` add a short tinted callout with just the reason so
    /// the concern is visible without repeating the pill.
    @ViewBuilder private var bodyVerdict: some View {
        if readiness.verdict != .ready {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: readiness.verdict.symbol)
                    .foregroundStyle(readiness.verdict.tone)
                Text(L10n.readinessReason(readiness.reason))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(readiness.verdict.tone.opacity(0.12), in: .rect(cornerRadius: 8))
        }
    }

    // MARK: - Packages

    private var packagesSection: some View {
        GroupBox {
            VStack(spacing: 6) {
                ForEach(bundle.packages, id: \.self) { pkg in
                    packageRow(pkg)
                }
            }
            .padding(.top, 2)
        } label: {
            Label(L10n.string("bundles.header.packages"), systemImage: "shippingbox")
        }
    }

    /// One package row: the existing installed check + name + kind capsule +
    /// trailing status/action, tappable to toggle an inline description accordion
    /// below it. The row toggle is an `.onTapGesture` (not a wrapping Button) so
    /// the trailing Install control — a real `Button` — consumes its own tap and
    /// installs the single package WITHOUT also toggling the description.
    @ViewBuilder private func packageRow(_ pkg: BundlePackage) -> some View {
        let installed = isInstalled(pkg)
        let key = rowKey(pkg)
        let isOpen = expanded.contains(key)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(installed ? .green : .secondary)
                Text(pkg.name).font(.callout)
                Text(packageKindLabel(pkg.kind))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                Spacer()
                packageStatus(pkg, key: key, installed: installed)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .contentShape(.rect)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onTapGesture { toggle(key) }
            .help(isOpen ? L10n.string("bundles.hideDescription") : L10n.string("bundles.showDescription"))

            if isOpen {
                descriptionArea(for: pkg, key: key)
                    .padding(.leading, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Trailing status/action for a package row. Installed → inert "Installed"
    /// text (pairs with the leading green checkmark). Installing → a spinner +
    /// "Installing…". Otherwise a per-package Install button that streams JUST
    /// this package via `AppModel.installPackage(_:)`. Being a real `Button`, it
    /// consumes its own tap, so it never fires the row's accordion toggle; the
    /// row flips to "Installed" on success (the streamed job refreshes the
    /// library) and reverts to this button on failure.
    @ViewBuilder private func packageStatus(_ pkg: BundlePackage, key: String, installed: Bool) -> some View {
        if installed {
            Text(L10n.string("bundles.state.installed")).font(.caption).foregroundStyle(.secondary)
        } else if installing.contains(key) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(L10n.string("action.installing")).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Button {
                launchPackageInstall(pkg, key: key)
            } label: {
                Label(L10n.string("action.install"), systemImage: "arrow.down.circle").font(.caption)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(String(format: L10n.string("bundles.package.installHelp.format"), pkg.name))
        }
    }

    /// Inline description shown under an expanded row. Loads lazily on first
    /// appear (via `.task`, so collapsing cancels an in-flight fetch) and reads
    /// from the `descriptions` cache on every subsequent expand.
    @ViewBuilder private func descriptionArea(for pkg: BundlePackage, key: String) -> some View {
        if let desc = descriptions[key] {
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.string("bundles.loadingDescription")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await loadDescription(pkg, key: key) }
        }
    }

    // MARK: - Caveats

    private func caveatsCard(_ caveats: String) -> some View {
        GroupBox {
            Text(caveats)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.top, 2)
        } label: {
            Label(L10n.string("bundles.caveats"), systemImage: "exclamationmark.bubble")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Setup checklist (M4)

    /// Ordered post-install checklist. brew-native steps (service/open/reveal)
    /// get action buttons; `command` steps are COPY-ONLY and marked "you run
    /// this" — the app never executes arbitrary shell (`external:true` contract).
    /// Shown pre- and post-install so the user sees the whole recipe.
    private func setupSection(_ steps: [SetupStep]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    L10n.string("bundles.setupHint.before")
                    + " "
                    + L10n.string("bundles.setupHint.youRunThis")
                    + " "
                    + L10n.string("bundles.setupHint.after")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    SetupStepRow(model: model, step: step, number: index + 1)
                    if index < steps.count - 1 { Divider() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            Label(L10n.string("bundles.setup"), systemImage: "checklist")
        }
    }

    // MARK: - Links

    private func linksSection(_ links: [BundleLink]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(links, id: \.self) { link in
                    if let url = URL(string: link.url) {
                        Link(destination: url) {
                            Label(link.label, systemImage: "arrow.up.right.square")
                                .font(.callout)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            Label(L10n.string("bundles.links"), systemImage: "link")
        }
    }

    // MARK: - Footer (Install all)

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                if readiness.verdict == .blocked {
                    confirmBlockedInstall = true
                } else {
                    launchInstall()
                }
            } label: {
                Label(installLabel, systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(pendingCount == 0)
            .confirmationDialog(
                L10n.string("bundles.installAnyway.native.title"),
                isPresented: $confirmBlockedInstall,
                titleVisibility: .visible
            ) {
                Button(L10n.string("bundles.installAnywayConfirm"), role: .destructive) { launchInstall() }
                Button(L10n.string("action.cancel"), role: .cancel) {}
            } message: {
                Text(
                    L10n.readinessReason(readiness.reason)
                    + "\n\n"
                    + String(format: L10n.string("bundles.installAnywayBody.format"), bundle.name)
                )
            }
        }
        .padding(16)
    }

    private var installLabel: String {
        if pendingCount == 0 { return L10n.string("bundles.allInstalled") }
        return pendingCount == bundle.packages.count
            ? L10n.string("bundles.installAll")
            : String(format: L10n.string("bundles.installMissing.format"), pendingCount)
    }

    // MARK: - Actions

    private func isInstalled(_ pkg: BundlePackage) -> Bool {
        let kind = InstalledPackage.Kind(rawValue: pkg.kind) ?? .formula
        return model.installedPackageMatching(token: pkg.name, kind: kind) != nil
    }

    /// Expansion/cache key — mirrors the installed-check keying (`name`+`kind`).
    private func rowKey(_ pkg: BundlePackage) -> String { pkg.name + pkg.kind }

    private func packageKindLabel(_ kind: String) -> String {
        kind == "cask" ? L10n.string("package.kind.cask") : L10n.string("package.kind.formula")
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    /// Resolve and cache a package's one-line description on first expand. Prefers
    /// resident catalog metadata, falling back to `brew info` — all inside
    /// `AppModel.packageDescription`. Missing descriptions cache a graceful
    /// fallback so the row doesn't keep spinning or re-fetch.
    private func loadDescription(_ pkg: BundlePackage, key: String) async {
        guard descriptions[key] == nil else { return }
        let kind = InstalledPackage.Kind(rawValue: pkg.kind) ?? .formula
        let resolved = await model.packageDescription(name: pkg.name, kind: kind)
        descriptions[key] = (resolved?.isEmpty == false) ? resolved! : L10n.string("bundles.noDescription")
    }

    /// Kick off the streaming install. The Activity drawer (auto-opened by
    /// `startJob`) is a persistent bottom bar under the split view, so the
    /// inspector stays open — the package rows flip to "Installed" live as the
    /// job completes. Closing is left to the inspector's ⊗ box.
    private func launchInstall() {
        let b = bundle
        Task { await model.installBundle(b) }
    }

    /// Stream a single package's install (per-row Install button). Marks the row
    /// "Installing…" for the duration, delegating to `AppModel.installPackage(_:)`
    /// — the same streamed `startJob` path "Install all" uses, scoped to one
    /// package. On completion the installing flag clears: success shows through
    /// as "Installed" (the job refreshed the library), failure reverts to the
    /// Install button with the error already surfaced in Activity. The inspector
    /// stays open throughout.
    private func launchPackageInstall(_ pkg: BundlePackage, key: String) {
        installing.insert(key)
        Task {
            await model.installPackage(pkg)
            installing.remove(key)
        }
    }
}

/// One row of the setup checklist. The kind drives the row: brew-native steps
/// (`service`/`open`/`reveal`) get an action button; `command` is copy-only and
/// visibly marked "you run this"; `note` is plain/markdown text. There is NO
/// code path that executes a `command`/external step — that is the automation
/// boundary the recipe contract guarantees.
struct SetupStepRow: View {
    @Bindable var model: AppModel
    let step: SetupStep
    let number: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch step.kind {
        case "service": serviceRow
        case "open":    openRow
        case "reveal":  revealRow
        case "command": commandRow
        case "note":    noteRow
        default:        noteRow   // unknown kind → show its text/label, no action
        }
    }

    // MARK: service → "Start" (disabled until the package is installed)

    private var serviceRow: some View {
        let service = step.service ?? ""
        // brew services are formulae — best-effort installed check.
        let installed = !service.isEmpty
            && model.installedPackageMatching(token: service, kind: .formula) != nil
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(step.label ?? (service.isEmpty ? L10n.string("action.start") : String(format: L10n.string("bundles.step.startServiceNamed.format"), service))).font(.callout)
                if !installed {
                    Text(service.isEmpty
                         ? L10n.string("bundles.step.installFirst.native.generic")
                         : String(format: L10n.string("bundles.step.installFirst.native.format"), service))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(L10n.string("action.start")) {
                Task { await model.performServiceAction(.start, name: service) }
            }
            .disabled(!installed)
            .help(installed ? "brew services start \(service)"
                            : L10n.string("bundles.step.serviceNotInstalled"))
        }
    }

    // MARK: open → "Open" (http/https only)

    private var openRow: some View {
        let url = validHttpURL(step.url)
        return HStack(alignment: .top, spacing: 8) {
            Text(step.label ?? String(format: L10n.string("bundles.action.open.format"), step.url ?? "")).font(.callout)
            Spacer(minLength: 8)
            Button(L10n.string("bundles.action.open")) { if let url { NSWorkspace.shared.open(url) } }
                .disabled(url == nil)
                .help(step.url ?? "")
        }
    }

    // MARK: reveal → "Reveal" in Finder

    private var revealRow: some View {
        let path = step.path ?? ""
        return HStack(alignment: .top, spacing: 8) {
            Text(step.label ?? String(format: L10n.string("bundles.action.reveal.format"), path)).font(.callout)
            Spacer(minLength: 8)
            Button(L10n.string("bundles.action.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .disabled(path.isEmpty)
            .help(path)
        }
    }

    // MARK: command → COPY-ONLY, "you run this" (never executed)

    private var commandRow: some View {
        let run = step.run ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                if let label = step.label { Text(label).font(.callout) }
                Spacer(minLength: 8)
                // A copy affordance only — deliberately NOT a run/execute button.
                Label(L10n.string("bundles.setupHint.youRunThis"), systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(run, forType: .string)
                    model.pushToast(.success, L10n.string("bundles.toast.copied"))
                } label: {
                    Label(L10n.string("bundles.action.copy"), systemImage: "doc.on.doc")
                }
                .disabled(run.isEmpty)
            }
            Text(run)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 6))
        }
    }

    // MARK: note → text (markdown if it parses)

    private var noteRow: some View {
        noteText(step.text ?? step.label ?? "")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    // MARK: helpers

    /// Render a note as inline markdown when it parses, else as plain text.
    private func noteText(_ s: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(s)
    }

    /// Only http/https URLs are openable — the `open`-step allowlist (mirrors the
    /// scheme guard used for cask homepages). Returns nil for anything else.
    private func validHttpURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}
