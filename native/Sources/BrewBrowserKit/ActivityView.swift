import SwiftUI
import AppKit

/// Bottom Activity drawer — live console for the active streaming job (install /
/// upgrade / uninstall / update). Mirrors the Tauri `ActivityDrawer`: collapsed
/// shows a one-line status; expanded shows the scrolling output with copy,
/// cancel, a completion footer, and (with 2+ jobs) a view-only segmented
/// switcher. Mounted as a bottom bar below the split view.
struct ActivityDrawer: View {
    @Bindable var model: AppModel
    /// `VSplitView` owns the live divider when expanded. The collapsed drawer
    /// keeps its existing compact bar layout.
    let fillsAvailableHeight: Bool

    init(model: AppModel, fillsAvailableHeight: Bool = false) {
        self.model = model
        self.fillsAvailableHeight = fillsAvailableHeight
    }

    /// The existing 200 px console plus the header and native split divider.
    /// This keeps an expanded drawer from becoming smaller than before.
    static let minimumConsoleHeight: CGFloat = 200
    static let minimumDrawerHeight: CGFloat = 252

    static func clampedDrawerHeight(_ height: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(height, minimumDrawerHeight), max(minimumDrawerHeight, maximum))
    }

    /// The drawer shows the explicitly-active job only. nil `activeJobId`
    /// (after Close) hides the drawer entirely; selecting a job in the Activity
    /// panel or starting a new one re-populates it.
    private var job: ActivityJob? {
        guard let id = model.activeJobId else { return nil }
        return model.jobs.first { $0.id == id }
    }

    /// Status-aware header label. The job's stored `label` is the in-progress
    /// form ("Installing X"); on completion show the terminal form so a green ✓
    /// doesn't sit next to "Installing".
    static func displayLabel(_ job: ActivityJob) -> String {
        switch job.status {
        case .running:   return job.label
        case .succeeded: return job.label
                .replacingOccurrences(of: "Installing ", with: "Installed ")
                .replacingOccurrences(of: "Upgrading ", with: "Upgraded ")
                .replacingOccurrences(of: "Uninstalling ", with: "Uninstalled ")
        case .failed:    return "Failed: \(job.label)"
        case .canceled:  return "Canceled: \(job.label)"
        }
    }

    var body: some View {
        if let job {
            VStack(spacing: 0) {
                Divider()
                header(job)
                if job.status == .running, let p = job.progress {
                    progressBar(p)
                }
                if model.drawerOpen {
                    expandedContent(job)
                    footer(job)
                }
            }
            // Full bleed edge-to-edge so the bar covers the window's rounded
            // bottom corners (no dark notch where the split-view corner shows
            // through). .bar material fills the whole width.
            .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight && model.drawerOpen ? .infinity : nil)
            .background(.bar)
            // Auto-collapse the console when a job finishes successfully — keeps
            // the one-line status visible (+ in Activity history) without the
            // 200px console lingering. Failures stay expanded so the error is seen.
            .onChange(of: job.status) { _, status in
                if status == .succeeded { model.drawerOpen = false }
            }
        }
    }

    private func header(_ job: ActivityJob) -> some View {
        HStack(spacing: 8) {
            statusIcon(job.status)
            Text(Self.displayLabel(job)).font(.callout.weight(.medium)).lineLimit(1)
            if job.status == .running {
                // Live elapsed timer, refreshed each second off the timeline's
                // own date (no Date() in the view body).
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.elapsed(since: job.startedAt, now: ctx.date))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView().controlSize(.small)
            }
            Spacer()
            if job.status == .running {
                Button {
                    model.cancelJob(job.id)
                } label: { Label("Cancel", systemImage: "stop.circle") }
                .buttonStyle(.borderless)
            }
            Button {
                copyLog(job)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("Copy output")
            Button {
                model.drawerOpen.toggle()
            } label: {
                Image(systemName: model.drawerOpen ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .help(model.drawerOpen ? "Collapse" : "Expand")
            // Close — dismiss the drawer for this job (stays in Activity history).
            // Cancels first if it's still running. Mirrors the Tauri drawer's X.
            Button {
                if job.status == .running { model.cancelJob(job.id) }
                model.dismissDrawer()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture { model.drawerOpen.toggle() }
    }

    /// Live determinate progress bar from brew's `==>` markers (#57). Shows a
    /// determinate bar once a total is known, an indeterminate linear bar
    /// otherwise. Mirrors the Tauri Activity drawer's progress row.
    private func progressBar(_ p: JobProgress) -> some View {
        HStack(spacing: 8) {
            if let total = p.total, total > 0 {
                ProgressView(value: Double(min(p.current, total)), total: Double(total))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
            }
            Text(Self.progressLabel(p))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    static func progressLabel(_ p: JobProgress) -> String {
        var s = p.phase
        if !p.package.isEmpty { s += " \(p.package)" }
        if let total = p.total { s += " (\(p.current) of \(total))" }
        return s
    }

    @ViewBuilder
    private func expandedContent(_ job: ActivityJob) -> some View {
        HStack(alignment: .top, spacing: 0) {
            console(job)
                .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
            if job.status == .failed {
                failureNotice(job)
                    .frame(width: 360)
            }
        }
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
    }

    private func failureNotice(_ job: ActivityJob) -> some View {
        // Classify once. Recovery (install/uninstall) owns its own retry buttons;
        // otherwise a failed `brew upgrade` with named per-package failures gets
        // the additive "Run in Terminal" hand-off below the message.
        let recovery = BrewRecovery.classify(job)
        let partial = recovery == nil ? PartialUpgrade.classify(job) : nil
        // A partial success ("Upgraded N …") is not a flat failure — soften the title.
        let title = (partial?.upgraded ?? 0) > 0
            ? "Upgrade incomplete"
            : AppModel.failureNoticeTitle(for: job.label)

        return Group {
            if job.status == .failed {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.body)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.callout.weight(.semibold))
                        if let recovery {
                            // A recoverable brew failure (#13/#102/#100): offer a
                            // one-click retry with the right flag instead of Terminal.
                            Text(recovery.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                ForEach(recovery.choices) { spec in
                                    Button(spec.label) {
                                        Task { await model.runRecovery(recovery, choice: spec.choice) }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(spec.isDanger ? .red : .accentColor)
                                    .help(spec.hint)
                                }
                            }
                            .padding(.top, 2)
                            if let hint = recovery.choices.first?.hint {
                                Text(hint)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            // Message: a curated friendly message wins; else the
                            // partial-success summary; else the generic notice.
                            if let friendly = job.friendlyFailureMessage {
                                Text(friendly)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if let partial {
                                Text(Self.partialSummary(partial))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if !AppModel.isAppError(job) {
                                Text("This looks like a Homebrew error, not a brew-browser bug — the command ran but exited with status \(job.exitCode ?? 0). Try the same command in Terminal; if it fails there too, it's a Homebrew or formula issue to report upstream.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("brew-browser hit an unexpected error running this command.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Report to brew-browser") {
                                    ReportIssue.open(for: job, brewVersion: model.brewVersion)
                                }
                                .buttonStyle(.link).font(.caption)
                            }

                            // Additive per-package Terminal hand-off — shown whenever
                            // the failed upgrade names packages, even alongside a
                            // curated message (e.g. the sudo-cask case), so the user
                            // gets a one-click prompt instead of typing the command.
                            if let partial {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(partial.failures, id: \.self) { name in
                                        HStack(spacing: 8) {
                                            Text(name).font(.caption.monospaced())
                                            Button("Run in Terminal") { model.openTerminalUpgrade(name) }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                                .help("Open Terminal running: brew upgrade \(name)")
                                        }
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.red.opacity(0.35), lineWidth: 1)
                )
                .padding(.top, 8)
                .padding(.trailing, 12)
                .padding(.leading, 8)
            }
        }
    }

    /// Body text for a partial-success upgrade (no curated friendly message).
    static func partialSummary(_ p: PartialUpgrade.Result) -> String {
        let n = p.failures.count
        let pkgWord = n == 1 ? "package" : "packages"
        if p.upgraded > 0 {
            let upWord = p.upgraded == 1 ? "package" : "packages"
            return "Upgraded \(p.upgraded) \(upWord) — \(n) \(pkgWord) couldn't upgrade automatically (often a cask that needs your password, or whose app was moved). Finish each in Terminal, where it can prompt you:"
        }
        return "\(n) \(pkgWord) couldn't upgrade automatically. Finish each in Terminal, where it can prompt you:"
    }

    private func console(_ job: ActivityJob) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(job.lines.enumerated()), id: \.offset) { idx, line in
                        Text(Self.stripANSI(line.text))
                            .font(.caption.monospaced())
                            .foregroundStyle(Self.lineColor(line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(minHeight: Self.minimumConsoleHeight,
                   maxHeight: fillsAvailableHeight ? .infinity : Self.minimumConsoleHeight)
            .onChange(of: job.lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    /// Completion footer — duration + (on failure) a Report button. Nothing
    /// while running. Mirrors the Tauri drawer footer.
    @ViewBuilder
    private func footer(_ job: ActivityJob) -> some View {
        if job.status != .running {
            HStack(spacing: 8) {
                Text(Self.footerText(job))
                    .font(.caption)
                    .foregroundStyle(Self.footerColor(job.status))
                    .lineLimit(3)
                if job.status == .failed && AppModel.isAppError(job) {
                    Button("Report to brew-browser") {
                        ReportIssue.open(for: job, brewVersion: model.brewVersion)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ActivityJob.JobStatus) -> some View {
        switch status {
        case .running:   Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .canceled:  Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }

    private func copyLog(_ job: ActivityJob) {
        let text = job.lines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Formatting helpers (static; pure)

    /// "m:ss" elapsed since an epoch-seconds start.
    static func elapsed(since start: Double, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince1970 - start))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Compact duration like "4.2s" from durationMs.
    static func duration(_ ms: Int?) -> String? {
        guard let ms else { return nil }
        return String(format: "%.1fs", Double(ms) / 1000)
    }

    static func footerText(_ job: ActivityJob) -> String {
        let dur = duration(job.durationMs)
        switch job.status {
        case .running:   return ""
        case .succeeded: return dur.map { "Done in \($0)." } ?? "Done."
        case .failed:
            let base = dur.map { "Failed after \($0)." } ?? "Failed."
            if let friendly = job.friendlyFailureMessage, !friendly.isEmpty {
                return "\(base) See notice at right."
            }
            if let code = job.exitCode, code != 0 { return "\(base) Exit \(code)." }
            return base
        case .canceled:  return "Stopped."
        }
    }

    static func footerColor(_ status: ActivityJob.JobStatus) -> Color {
        switch status {
        case .succeeded: return .green
        case .failed:    return .red
        default:         return .secondary
        }
    }

    /// Content-based line coloring, matching the Tauri drawer's `classifyLine`.
    static func lineColor(_ line: ActivityLine) -> Color {
        let text = stripANSI(line.text)
        let lower = text.lowercased()
        if text.hasPrefix("==>") { return .accentColor }
        if lower.contains("error:") { return .red }
        if lower.contains("warning:") { return .orange }
        if lower.hasPrefix("downloading") || lower.hasPrefix("pouring")
            || lower.hasPrefix("installing") || lower.hasPrefix("fetching") {
            return .green
        }
        if line.stream == .stderr { return .orange }
        return .primary
    }

    /// Strip ANSI CSI escape sequences. brew runs with HOMEBREW_NO_COLOR so it
    /// shouldn't emit any, but strip defensively (parity with Tauri).
    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }
}

/// The Activity panel — job history. Click a job to open it in the drawer;
/// swipe or right-click to remove a single job; "Clear Finished" clears them all.
struct ActivityView: View {
    @Bindable var model: AppModel

    /// Row the pointer is over — drives the hover-revealed remove button (parity
    /// with the Tauri history list's hover trash).
    @State private var hovered: UUID?

    var body: some View {
        Group {
            if model.jobs.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Installs, upgrades, uninstalls, and updates show up here.")
                )
            } else {
                List(model.jobs) { job in
                    HStack(spacing: 6) {
                        Button {
                            model.activeJobId = job.id
                            model.drawerOpen = true
                        } label: {
                            HStack(spacing: 10) {
                                icon(job.status)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.label).fontWeight(.medium)
                                    Text(job.command).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(statusText(job)).font(.caption).foregroundStyle(.secondary)
                                    if let dur = ActivityDrawer.duration(job.durationMs), job.status != .running {
                                        Text(dur).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)

                        // Hover-revealed remove (parity with Tauri's row trash).
                        // Reserves its gutter always so the row doesn't reflow on
                        // hover; only hit-testable while shown.
                        Button {
                            model.removeJob(job.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(hovered == job.id ? Color.red : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 24)
                        .opacity(hovered == job.id ? 1 : 0)
                        .allowsHitTesting(hovered == job.id)
                        .help("Remove from history")
                    }
                    .onHover { inside in
                        if inside { hovered = job.id }
                        else if hovered == job.id { hovered = nil }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.removeJob(job.id) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) { model.removeJob(job.id) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .toolbar {
            if model.jobs.contains(where: { $0.status != .running }) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Finished") { model.clearFinishedJobs() }
                }
            }
        }
    }

    /// Right-aligned status string; failures append their exit code.
    private func statusText(_ job: ActivityJob) -> String {
        if job.status == .failed, let code = job.exitCode, code != 0 {
            return "Failed · exit \(code)"
        }
        return job.status.rawValue.capitalized
    }

    @ViewBuilder
    private func icon(_ status: ActivityJob.JobStatus) -> some View {
        switch status {
        case .running:   Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .canceled:  Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}
