import Foundation

/// Lightweight native localization facade.
///
/// Static SwiftUI strings use String Catalog keys directly through this helper.
/// Model-derived strings stay structured until render time so persisted raw
/// values, package names, brew commands, and Recent Changes parsing remain
/// stable across locales.
public enum L10n {
    public static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    static var isRussian: Bool {
        Locale.autoupdatingCurrent.identifier.lowercased().hasPrefix("ru")
    }

    static func ruPlural(_ n: Int, one: String, few: String, many: String) -> String {
        let absN = abs(n)
        let mod10 = absN % 10
        let mod100 = absN % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }

    static func vulnerablePackages(_ count: Int) -> String {
        if isRussian {
            return "\(count) \(ruPlural(count, one: "уязвимый пакет", few: "уязвимых пакета", many: "уязвимых пакетов"))"
        }
        return "\(count) vulnerable package\(count == 1 ? "" : "s")"
    }

    static func vulnerablePackagesHelp(_ count: Int) -> String {
        if isRussian {
            let packages = ruPlural(count, one: "установленный пакет содержит", few: "установленных пакета содержат", many: "установленных пакетов содержат")
            return "\(count) \(packages) известные уязвимости. Нажмите, чтобы открыть их в Библиотеке."
        }
        return "\(count) installed package\(count == 1 ? " has" : "s have") known vulnerabilities. Click to view them in Library."
    }

    static func servicesSummary(running: Int, total: Int) -> String {
        if isRussian {
            let runningWord = ruPlural(running, one: "запущена", few: "запущены", many: "запущено")
            return "\(running) \(runningWord) · всего \(total)"
        }
        return "\(running) running · \(total) total"
    }

    static func selectedCount(_ selected: Int, total: Int) -> String {
        if isRussian {
            return "Выбрано \(selected) из \(total)"
        }
        return "\(selected) of \(total) selected"
    }

    static func catalogAge(days: Int) -> String {
        if days <= 0 { return string("date.today") }
        if isRussian {
            return "\(days) \(ruPlural(days, one: "день", few: "дня", many: "дней"))"
        }
        if days == 1 { return "1 day old" }
        return "\(days) days old"
    }

    static func upgradePackageButton(_ count: Int) -> String {
        if count == 0 { return string("action.upgrade") }
        if isRussian {
            return "Обновить \(count) \(ruPlural(count, one: "пакет", few: "пакета", many: "пакетов"))"
        }
        return "Upgrade \(count) package\(count == 1 ? "" : "s")"
    }

    static func exposureSummary(findings: Int, vulnerablePackages: Int, totalPackages: Int, source: String?) -> String {
        let sourceSuffix: String
        if let source {
            sourceSuffix = isRussian ? " · источник: \(source)" : " · source: \(source)"
        } else {
            sourceSuffix = ""
        }
        if isRussian {
            let findingWord = ruPlural(findings, one: "находка", few: "находки", many: "находок")
            let packageWord = ruPlural(totalPackages, one: "установленного пакета", few: "установленных пакетов", many: "установленных пакетов")
            return "\(findings) \(findingWord) в \(vulnerablePackages) из \(totalPackages) \(packageWord)\(sourceSuffix)"
        }
        return "\(findings) finding\(findings == 1 ? "" : "s") across \(vulnerablePackages) of \(totalPackages) installed packages\(sourceSuffix)"
    }

    static func severity(_ severity: VulnSeverity) -> String {
        switch severity {
        case .critical: return isRussian ? "критическая" : "critical"
        case .high: return isRussian ? "высокая" : "high"
        case .medium: return isRussian ? "средняя" : "medium"
        case .low: return isRussian ? "низкая" : "low"
        case .unknown: return isRussian ? "неизвестная" : "unknown"
        }
    }

    static func severityTitle(_ severity: VulnSeverity) -> String {
        if !isRussian { return severity.rawValue.capitalized }
        switch severity {
        case .critical: return "Критическая"
        case .high: return "Высокая"
        case .medium: return "Средняя"
        case .low: return "Низкая"
        case .unknown: return "Неизвестная"
        }
    }

    static func vulnerabilityDotHelp(count: Int, severity: VulnSeverity) -> String {
        if isRussian {
            let findingWord = ruPlural(count, one: "известная уязвимость", few: "известные уязвимости", many: "известных уязвимостей")
            return "\(count) \(findingWord) (наивысшая серьёзность: \(self.severity(severity))). Нажмите строку, чтобы посмотреть детали."
        }
        return "\(count) known vulnerabilit\(count == 1 ? "y" : "ies") (highest: \(severity.rawValue)). Click row to see details."
    }

    static func githubCheckingStarred(total: Int) -> String {
        if total <= 0 { return string("github.checkingStarred") }
        if isRussian {
            let packageWord = ruPlural(total, one: "пакета", few: "пакетов", many: "пакетов")
            return "Проверяем, какие из \(total) \(packageWord) вы отметили звёздочкой..."
        }
        return "Checking which of your \(total) packages you've starred..."
    }

    static func githubStarredSummary(starred: Int, total: Int) -> String {
        if isRussian {
            let packageWord = ruPlural(total, one: "установленного пакета", few: "установленных пакетов", many: "установленных пакетов")
            return "Вы отметили звёздочкой \(starred) из \(total) \(packageWord) с GitHub homepage."
        }
        return "You've starred \(starred) of \(total) installed packages with GitHub homepages."
    }

    static func moreInLibrary(_ count: Int) -> String {
        if isRussian {
            return "+ ещё \(count) в Библиотеке"
        }
        return "+ \(count) more in Library"
    }

    static func activityDisplayLabel(_ job: ActivityJob) -> String {
        if !isRussian { return englishActivityDisplayLabel(job) }
        let running = russianActivityLabel(job.label)
        switch job.status {
        case .running:
            return running
        case .succeeded:
            return russianCompletedActivityLabel(job.label) ?? running
        case .failed:
            return "Ошибка: \(running)"
        case .canceled:
            return "Отменено: \(running)"
        }
    }

    private static func englishActivityDisplayLabel(_ job: ActivityJob) -> String {
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

    private static func russianActivityLabel(_ label: String) -> String {
        if label == "Updating Homebrew" { return "Обновляем Homebrew" }
        if label == "Running brew doctor" { return "Выполняем brew doctor" }
        if label == "Cleaning up Homebrew cache" { return "Очищаем кэш Homebrew" }
        if label == "Upgrading all packages" { return "Обновляем все пакеты" }
        if label == "Removing unused dependencies" { return "Удаляем неиспользуемые зависимости" }
        if let name = label.removingPrefix("Installing ") { return "Устанавливаем \(name)" }
        if let name = label.removingPrefix("Upgrading ") { return "Обновляем \(name)" }
        if let name = label.removingPrefix("Uninstalling ") { return "Удаляем \(name)" }
        if let label = label.removingPrefix("Dumping Brewfile: ") { return "Создаём Brewfile: \(label)" }
        if let label = label.removingPrefix("Restoring ") { return "Восстанавливаем \(label)" }
        return label
    }

    private static func russianCompletedActivityLabel(_ label: String) -> String? {
        if label == "Updating Homebrew" { return "Homebrew обновлён" }
        if label == "Running brew doctor" { return "brew doctor завершён" }
        if label == "Cleaning up Homebrew cache" { return "Кэш Homebrew очищен" }
        if label == "Upgrading all packages" { return "Все пакеты обновлены" }
        if label == "Removing unused dependencies" { return "Неиспользуемые зависимости удалены" }
        if let name = label.removingPrefix("Installing ") { return "Установлено \(name)" }
        if let name = label.removingPrefix("Upgrading ") { return "Обновлено \(name)" }
        if let name = label.removingPrefix("Uninstalling ") { return "Удалено \(name)" }
        if let label = label.removingPrefix("Dumping Brewfile: ") { return "Brewfile создан: \(label)" }
        if let label = label.removingPrefix("Restoring ") { return "Восстановлено \(label)" }
        return nil
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
