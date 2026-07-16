import AppKit
import UserNotifications

/// macOS notifications for "brew task finished" — the native advantage over the
/// web build: post a system notification when a long brew job completes while
/// the app isn't frontmost. Opt-in (`LocalPrefs.notifyOnTaskCompletion`); auth
/// is requested only when the user enables the toggle (no surprise launch
/// prompt). Foreground completion is left to the Activity drawer.
@MainActor
enum NotificationService {

    /// `UNUserNotificationCenter.current()` traps if the process has no bundle
    /// identifier (e.g. a bare `swift run`). The `.app` bundle sets one, so
    /// notifications work there; this guard keeps a bundle-less run from crashing.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// Request authorization. Called when the user flips the toggle on — the
    /// prompt then reads as a direct consequence of their action.
    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a completion notification, but only when (a) the user opted in,
    /// (b) the app isn't frontmost (foreground gets the live drawer), and
    /// (c) authorization was granted. Silent no-op otherwise.
    static func notifyTaskFinished(label: String, succeeded: Bool, canceled: Bool) {
        guard available, LocalPrefs.shared.notifyOnTaskCompletion else { return }
        guard !NSApp.isActive else { return }           // foreground → Activity drawer
        if canceled { return }                          // user-initiated cancel: no notification

        // Re-fetch `current()` inside the completion rather than capturing the
        // (non-Sendable) center into the @Sendable closure. Only `succeeded` +
        // `label` (both Sendable) are captured.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = succeeded
                ? (L10n.isRussian ? "Задача Homebrew завершена" : "Homebrew task finished")
                : (L10n.isRussian ? "Задача Homebrew завершилась ошибкой" : "Homebrew task failed")
            content.body = L10n.activityNotificationBody(label: label, succeeded: succeeded)
            if !succeeded { content.sound = .default }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }
}
