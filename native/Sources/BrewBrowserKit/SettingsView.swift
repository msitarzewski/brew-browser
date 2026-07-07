import SwiftUI

/// Native Settings scene — stock `Settings { }` + `TabView`, opened by ⌘, or
/// the toolbar gear (SettingsLink). Ports the Tauri Settings modal, with the
/// previously-nested subsections (Updates, Vulnerabilities, Trending History)
/// promoted to their own top-level tabs per the macOS preferences convention.
///
/// Persistence is split exactly like the Tauri app:
///   - gated/network feature toggles → `AppSettings.shared` (settings.json)
///   - local UI prefs → `LocalPrefs.shared` (UserDefaults)
/// Native Settings — stock `TabView` with the default top tab bar. This is the
/// canonical SwiftUI macOS preferences shape; we tried sidebar variants and the
/// default is cleaner and simpler. Opened by ⌘, and the toolbar gear.
/// Settings tabs, shared so other surfaces (e.g. the toolbar Octocat) can open
/// Settings to a specific pane via the `SettingsTab.deepLink` AppStorage key.
public enum SettingsTab: String { case appearance, network, github, brew, updates, security, trending, activity, about }

public struct SettingsView: View {
    /// Persisted selection — also the deep-link target: writing this key before
    /// `openSettings()` makes Settings open to that pane.
    @AppStorage("settings.selectedTab") private var selected = SettingsTab.appearance.rawValue

    /// The Sparkle updater, owned by the app scene and passed in so the Updates
    /// tab's "Check now" / auto-check controls drive the shared instance (Bundle C).
    private let updater: UpdaterController

    /// The shared app model, passed in so the Brew tab's Autoremove action can
    /// stream a job into Activity (parity with the Tauri Settings → Brew).
    private let model: AppModel

    public init(model: AppModel, updater: UpdaterController) {
        self.model = model
        self.updater = updater
    }

    public var body: some View {
        TabView(selection: $selected) {
            AppearanceSettings()
                .tabItem { Label(L10n.string("settings.section.appearance"), systemImage: "paintbrush") }.tag(SettingsTab.appearance.rawValue)
            NetworkSettings()
                .tabItem { Label(L10n.string("settings.section.network"), systemImage: "globe") }.tag(SettingsTab.network.rawValue)
            GitHubSettings()
                .tabItem { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }.tag(SettingsTab.github.rawValue)
            BrewSettings(model: model)
                .tabItem { Label("Brew", systemImage: "mug") }.tag(SettingsTab.brew.rawValue)
            UpdatesSettings(updater: updater)
                .tabItem { Label(L10n.string("settings.section.updates"), systemImage: "arrow.down.circle") }.tag(SettingsTab.updates.rawValue)
            VulnerabilitySettings()
                .tabItem { Label(L10n.string("settings.section.security"), systemImage: "shield") }.tag(SettingsTab.security.rawValue)
            TrendingSettings()
                .tabItem { Label(L10n.string("nav.trending"), systemImage: "chart.line.uptrend.xyaxis") }.tag(SettingsTab.trending.rawValue)
            ActivitySettings()
                .tabItem { Label(L10n.string("nav.activity"), systemImage: "list.bullet.rectangle") }.tag(SettingsTab.activity.rawValue)
            AboutSettings()
                .tabItem { Label(L10n.string("settings.section.about"), systemImage: "info.circle") }.tag(SettingsTab.about.rawValue)
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @State private var prefs = LocalPrefs.shared
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Picker(L10n.string("theme.label"), selection: $prefs.theme) {
                ForEach(AppTheme.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: prefs.theme) { _, _ in prefs.applyTheme() }

            Picker(L10n.string("settings.appearance.defaultLanding"), selection: $prefs.defaultSection) {
                ForEach(LandingSection.allCases, id: \.self) { Text($0.label).tag($0) }
            }

            SwiftUI.Section {
                Toggle(L10n.string("settings.appearance.aiFeatures"), isOn: Binding(
                    get: { settings.aiFeaturesEnabled },
                    set: { settings.aiFeaturesEnabled = $0; try? settings.save() }
                ))
                Text(L10n.string("settings.appearance.aiFeatures.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Network

private struct NetworkSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle(L10n.string("settings.network.offlineMode"), isOn: Binding(
                    get: { settings.paranoidMode },
                    set: { settings.paranoidMode = $0; try? settings.save() }
                ))
                Text(L10n.string("settings.network.offlineMode.help"))
                    .font(.caption).foregroundStyle(.secondary)
                if settings.paranoidMode {
                    Label(L10n.string("settings.network.offlineMode.on"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            SwiftUI.Section {
                Picker(L10n.string("settings.network.catalogAutoRefresh"), selection: Binding(
                    get: { settings.catalogAutoRefresh },
                    set: { settings.catalogAutoRefresh = $0; try? settings.save() }
                )) {
                    Text(L10n.string("settings.option.off")).tag(CatalogAutoRefresh.off)
                    Text(L10n.string("settings.option.weekly")).tag(CatalogAutoRefresh.weekly)
                    Text(L10n.string("settings.option.daily")).tag(CatalogAutoRefresh.daily)
                }
                .pickerStyle(.segmented)
                .disabled(settings.isCorrupt)

                Stepper(value: Binding(
                    get: { Int(settings.catalogStaleBannerDays) },
                    set: { settings.catalogStaleBannerDays = UInt32($0); try? settings.save() }
                ), in: 1...365) {
                    Text(String(format: L10n.string("settings.network.catalogStaleThreshold.format"), Int(settings.catalogStaleBannerDays)))
                }

                Picker(L10n.string("settings.network.caskIconFetching"), selection: Binding(
                    get: { settings.caskIconMode },
                    set: { settings.caskIconMode = $0; try? settings.save() }
                )) {
                    Text(L10n.string("settings.option.off")).tag(CaskIconMode.off)
                    Text(L10n.string("settings.option.installedOnly")).tag(CaskIconMode.installedOnly)
                    Text(L10n.string("filter.all")).tag(CaskIconMode.all)
                }
                .pickerStyle(.segmented)

                Stepper(value: Binding(
                    get: { Int(settings.trendingTtlMinutes) },
                    set: { settings.trendingTtlMinutes = UInt32($0); try? settings.save() }
                ), in: 5...1440, step: 5) {
                    Text(String(format: L10n.string("settings.network.trendingTtl.format"), Int(settings.trendingTtlMinutes)))
                }
            }

            if settings.isCorrupt {
                SwiftUI.Section {
                    Label(L10n.string("settings.fileUnreadable"), systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Button(L10n.string("settings.resetToDefaults")) { settings.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - GitHub

private struct GitHubSettings: View {
    @State private var settings = AppSettings.shared
    @State private var github = GitHubService()
    @State private var status: GithubStatus?
    @State private var flow: DeviceFlowStart?
    @State private var signingIn = false
    @State private var error: String?

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle(L10n.string("settings.github.showStats"), isOn: Binding(
                    get: { settings.githubEnabled },
                    set: { settings.githubEnabled = $0; try? settings.save() }
                ))
                Text(L10n.string("settings.github.showStats.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section(L10n.string("github.signIn")) {
                if let status, status.signedIn {
                    LabeledContent(L10n.string("github.signedInAs"), value: "@\(status.username ?? "?")")
                    if !status.scopes.isEmpty {
                        LabeledContent("Scopes", value: status.scopes.joined(separator: ", "))
                            .font(.caption)
                    }
                    Button(L10n.string("github.signOut")) {
                        Task {
                            github.signOut()
                            self.status = github.status()
                        }
                    }
                } else if let flow {
                    LabeledContent(L10n.string("github.yourCode"), value: flow.userCode)
                        .font(.body.monospaced())
                    Text(String(format: L10n.string("github.deviceFlowInstructions.format"), flow.verificationUri))
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await startSignIn() }
                    } label: {
                        Label(L10n.string("github.signInWithGitHub"), systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(signingIn)
                    Text(L10n.string("github.signIn.help"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            SwiftUI.Section {
                Text(L10n.string("github.keychain.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .task { status = github.status() }
    }

    private func startSignIn() async {
        signingIn = true
        error = nil
        do {
            let start = try await github.startDeviceFlow()
            flow = start
            if let url = URL(string: start.verificationUri) { NSWorkspace.shared.open(url) }
            // Copy the code so the user can paste it.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(start.userCode, forType: .string)
            let result = try await github.pollDeviceFlow(deviceCode: start.deviceCode, interval: start.interval)
            status = result
            flow = nil
        } catch {
            self.error = error.localizedDescription
            flow = nil
        }
        signingIn = false
    }
}

// MARK: - Brew

private struct BrewSettings: View {
    @Bindable var model: AppModel
    @State private var prefs = LocalPrefs.shared
    @State private var brew = BrewService()
    @State private var analytics: Bool?
    @State private var analyticsBusy = false
    @State private var confirmAutoremove = false

    var body: some View {
        Form {
            SwiftUI.Section(L10n.string("settings.brew.analytics")) {
                Toggle(L10n.string("settings.brew.sendAnalytics"), isOn: Binding(
                    get: { analytics ?? false },
                    set: { newValue in
                        Task {
                            analyticsBusy = true
                            try? await brew.setAnalytics(newValue)
                            analytics = newValue
                            analyticsBusy = false
                        }
                    }
                ))
                .disabled(analytics == nil || analyticsBusy)
                Text(L10n.string("settings.brew.analytics.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section(L10n.string("settings.brew.confirmations")) {
                Toggle(L10n.string("settings.brew.confirmDestructive"), isOn: $prefs.confirmDestructive)
                Text(L10n.string("settings.brew.confirmDestructive.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section(L10n.string("settings.brew.advanced")) {
                Toggle(L10n.string("settings.brew.greedyUpgrades"), isOn: $prefs.greedyUpgrade)
                Text(L10n.string("settings.brew.greedyUpgrades.help"))
                    .font(.caption).foregroundStyle(.secondary)

                Button(L10n.string("settings.brew.autoremoveUnused")) {
                    if prefs.confirmDestructive { confirmAutoremove = true }
                    else { Task { await model.autoremove() } }
                }
                Text(L10n.string("settings.brew.autoremove.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .task { analytics = await brew.getAnalytics() }
        .confirmationDialog(L10n.string("settings.brew.autoremove.confirmTitle"), isPresented: $confirmAutoremove, titleVisibility: .visible) {
            Button(L10n.string("settings.brew.autoremove"), role: .destructive) { Task { await model.autoremove() } }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("settings.brew.autoremove.confirmMessage"))
        }
    }
}

// MARK: - Updates

private struct UpdatesSettings: View {
    @State private var settings = AppSettings.shared
    /// The shared Sparkle updater (Bundle C). `@Bindable` so the "Automatically
    /// check" toggle can bind through to it and the view re-renders when its
    /// observable state (canCheckForUpdates, lastUpdateCheckDate) changes.
    @Bindable var updater: UpdaterController

    /// Offline Mode gates the manual check — same posture as the Tauri "Check
    /// now" button (`SettingsSectionUpdates.svelte:107`).
    private var offline: Bool { settings.paranoidMode }

    var body: some View {
        Form {
            // Check now — runs Sparkle's check, which presents the standard
            // update UI if a newer build is on the feed. Disabled while a check
            // is already in flight (canCheckForUpdates) or in Offline Mode.
            SwiftUI.Section {
                HStack {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label(L10n.string("updates.checkNow"), systemImage: "arrow.clockwise")
                    }
                    .disabled(offline || !updater.canCheckForUpdates)
                    Spacer()
                    Text(String(format: L10n.string("updates.lastChecked.format"), lastCheckedLabel))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if offline {
                    Label(L10n.string("updates.offlineBlocked"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text(L10n.string("updates.check.help"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Auto-check — binds Sparkle's automaticallyChecksForUpdates (its
            // standard, persisted preference). Stays toggleable even in Offline
            // Mode so the preference is set for the next time it's off, matching
            // the Tauri auto-check toggle and every other network toggle.
            SwiftUI.Section {
                Toggle(L10n.string("updates.autoCheck"), isOn: $updater.automaticallyChecksForUpdates)
                Text(L10n.string("updates.autoCheck.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section(L10n.string("updates.channel")) {
                LabeledContent(L10n.string("updates.channel.label"), value: L10n.string("updates.channel.stable"))
                Text(L10n.string("updates.noBeta"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    /// Last-checked relative date ("2 hours ago"), or "Never" before the first
    /// check. Mirrors the Tauri `lastCheckedLabel`.
    private var lastCheckedLabel: String {
        guard let date = updater.lastUpdateCheckDate else { return L10n.string("updates.never") }
        return date.formatted(.relative(presentation: .named))
    }
}

// MARK: - Vulnerabilities

private struct VulnerabilitySettings: View {
    @State private var settings = AppSettings.shared
    @State private var vulns = VulnsService()
    @State private var helperInstalled: Bool?
    @State private var installing = false

    private var offline: Bool { settings.paranoidMode }

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle(L10n.string("security.scanInstalled"), isOn: Binding(
                    get: { settings.vulnerabilityScanningEnabled },
                    set: { settings.vulnerabilityScanningEnabled = $0; try? settings.save() }
                ))
                .disabled(offline || settings.isCorrupt)
                Text(L10n.string("security.scanInstalled.help"))
                    .font(.caption).foregroundStyle(.secondary)
                if offline {
                    Label(L10n.string("security.offlineSuppressed"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            if settings.vulnerabilityScanningEnabled && !offline {
                SwiftUI.Section {
                    if helperInstalled == false {
                        Text(L10n.string("security.brewVulnsMissing.help"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            Task {
                                installing = true
                                _ = try? await vulns.installHelper()
                                helperInstalled = await vulns.isBrewVulnsInstalled()
                                installing = false
                            }
                        } label: {
                            if installing {
                                HStack { ProgressView().controlSize(.small); Text(L10n.string("action.installing")) }
                            } else {
                                Label(L10n.string("security.installBrewVulns"), systemImage: "arrow.down.circle")
                            }
                        }
                        .disabled(installing)
                    } else if helperInstalled == true {
                        Label(L10n.string("security.brewVulnsInstalled"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .task { helperInstalled = await vulns.isBrewVulnsInstalled() }
    }
}

// MARK: - Trending History

private struct TrendingSettings: View {
    @State private var settings = AppSettings.shared
    private var offline: Bool { settings.paranoidMode }

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle(L10n.string("trending.fetchHistory"), isOn: Binding(
                    get: { settings.enhancedTrendingEnabled },
                    set: { settings.enhancedTrendingEnabled = $0; try? settings.save() }
                ))
                .disabled(offline || settings.isCorrupt)
                Text(L10n.string("trending.fetchHistory.help"))
                    .font(.caption).foregroundStyle(.secondary)
                if offline {
                    Label(L10n.string("settings.offlineToggleLocked"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            SwiftUI.Section {
                Toggle(L10n.string("enrichment.fetchLatest"), isOn: Binding(
                    get: { settings.liveEnrichmentEnabled },
                    set: { settings.liveEnrichmentEnabled = $0; try? settings.save() }
                ))
                .disabled(offline || settings.isCorrupt)
                Text(L10n.string("enrichment.fetchLatest.help"))
                    .font(.caption).foregroundStyle(.secondary)
                if offline {
                    Label(L10n.string("settings.offlineToggleLocked"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Activity

private struct ActivitySettings: View {
    @State private var prefs = LocalPrefs.shared

    var body: some View {
        Form {
            SwiftUI.Section {
                Stepper(value: $prefs.activityMaxJobs, in: 1...1000) {
                    Text(String(format: L10n.string("activity.keepJobs.format"), prefs.activityMaxJobs))
                }
                Stepper(value: $prefs.activityMaxLines, in: 100...10000, step: 50) {
                    Text(String(format: L10n.string("activity.linesPerJob.format"), prefs.activityMaxLines))
                }
                Text(L10n.string("activity.limits.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                Toggle(L10n.string("activity.notifyOnCompletion"), isOn: Binding(
                    get: { prefs.notifyOnTaskCompletion },
                    set: { on in
                        prefs.notifyOnTaskCompletion = on
                        if on { NotificationService.requestAuthorization() }
                    }
                ))
                Text(L10n.string("activity.notifyOnCompletion.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("App version", value: appVersion())
                LabeledContent("License", value: "MIT")
                Link("github.com/msitarzewski/brew-browser",
                     destination: URL(string: "https://github.com/msitarzewski/brew-browser")!)
            }
            SwiftUI.Section {
                Text("Zero telemetry. Zero accounts. brew-browser does not collect telemetry, phone home, or have user accounts. Every outbound request is documented in Settings → Network and only fires when you take an action that requires it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}
