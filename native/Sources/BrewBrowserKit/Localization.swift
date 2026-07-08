import Foundation

/// Lightweight native localization facade.
///
/// Static SwiftUI strings use String Catalog keys directly through this helper.
/// Model-derived strings stay structured until render time so persisted raw
/// values, package names, brew commands, and Recent Changes parsing remain
/// stable across locales.
public enum L10n {
    public static func string(_ key: String) -> String {
        let language = activeLanguage
        if let path = Bundle.module.path(forResource: language, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let value = bundle.localizedString(forKey: key, value: key, table: nil)
            if value != key { return value }
        }
        return Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }

    static func display(_ source: String) -> String {
        if !isRussian { return source }
        switch source {
        case "AI & ML": return "ИИ и ML"
        case "Browsers": return "Браузеры"
        case "Cloud & DevOps": return "Облако и DevOps"
        case "Communication": return "Коммуникации"
        case "Data": return "Данные"
        case "Developer Tools": return "Инструменты разработчика"
        case "Editors & IDEs": return "Редакторы и IDE"
        case "Education": return "Образование"
        case "Games & Entertainment": return "Игры и развлечения"
        case "Graphics & Design": return "Графика и дизайн"
        case "Music": return "Музыка"
        case "Office & Docs": return "Офис и документы"
        case "Productivity": return "Продуктивность"
        case "Security": return "Безопасность"
        case "System Utilities": return "Системные утилиты"
        case "Terminal": return "Терминал"
        case "Video & Audio": return "Видео и аудио"
        case "Writing": return "Работа с текстом"
        case "Uncategorized": return "Без категории"
        case "Other": return "Другое"
        case "Formulae": return "Формулы"
        case "Casks": return "Cask-пакеты"
        case "formulae": return "формул"
        case "casks": return "cask-пакетов"
        case "Formulae (Cellar)": return "Формулы (Cellar)"
        case "Casks (Caskroom)": return "Cask-пакеты (Caskroom)"
        case "Logs (var/log)": return "Логи (var/log)"
        case "Download cache": return "Кэш загрузок"
        case "installed": return "установлено"
        case "updates available": return "доступны обновления"
        case "checking updates": return "проверяем обновления"
        case "All current": return "Всё актуально"
        case "Disabled": return "Отключено"
        case "Deprecated": return "Устарело"
        case "Catalog": return "Каталог"
        case "Composition": return "Состав"
        case "Top categories in your library": return "Главные категории в библиотеке"
        case "Storage": return "Хранилище"
        case "Measuring disk usage…": return "Считаем место на диске…"
        case "Refresh": return "Обновить"
        case "Refreshing…": return "Обновляем…"
        case "Refresh from brew.sh →": return "Обновить с brew.sh →"
        case "Updates available": return "Доступны обновления"
        case "Choose…": return "Выбрать…"
        case "Running…": return "Выполняем…"
        case "Run brew doctor": return "Запустить brew doctor"
        case "Cleaning…": return "Очищаем…"
        case "Clean up cache…": return "Очистить кэш…"
        case "Scrub — also remove the latest versions' cached downloads (more aggressive)":
            return "Тщательная очистка: удалить также кэш загрузок последних версий (агрессивнее)"
        case "Verbose — list every file removed":
            return "Подробный вывод: перечислять каждый удалённый файл"
        case "Cancel": return "Отмена"
        case "Clean up": return "Очистить"
        case "bundled": return "встроенный"
        default:
            break
        }

        if let n = Int(source.removingSuffix(" on request") ?? "") {
            return "\(n) вручную"
        }
        if let n = Int(source.removingSuffix(" as dependency") ?? "") {
            return "\(n) \(ruPlural(n, one: "как зависимость", few: "как зависимости", many: "как зависимостей"))"
        }
        if let n = Int(source.removingSuffix(" pinned") ?? "") {
            return "\(n) \(ruPlural(n, one: "закреплённый", few: "закреплённых", many: "закреплённых"))"
        }
        if let n = Int(source.removingSuffix(" formulae") ?? "") {
            return "\(n) \(ruPlural(n, one: "формула", few: "формулы", many: "формул"))"
        }
        if let n = Int(source.removingSuffix(" casks") ?? "") {
            return "\(n) \(ruPlural(n, one: "cask-пакет", few: "cask-пакета", many: "cask-пакетов"))"
        }
        if let value = source.removingSuffix(" total") {
            return "всего \(value)"
        }
        if let value = source.removingPrefix("frees ~") {
            return "освободит ~\(value)"
        }
        if let value = source.removingPrefix("Catalog: ") {
            return "Каталог: \(value)"
        }
        if let value = source.removingPrefix("General ") {
            return "Общее: \(display(value))"
        }
        if source.contains(" + ") {
            return source
                .split(separator: "+", maxSplits: 1)
                .map { display($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: " + ")
        }
        return source
    }

    static func formulaeCount(_ count: Int) -> String {
        if isRussian {
            return "\(count) \(ruPlural(count, one: "формула", few: "формулы", many: "формул"))"
        }
        return "\(count) formulae"
    }

    static func casksCount(_ count: Int) -> String {
        if isRussian {
            return "\(count) \(ruPlural(count, one: "cask-пакет", few: "cask-пакета", many: "cask-пакетов"))"
        }
        return "\(count) casks"
    }

    static func packagesCount(_ count: Int) -> String {
        if isRussian {
            return "\(count) \(ruPlural(count, one: "пакет", few: "пакета", many: "пакетов"))"
        }
        return "\(count) package\(count == 1 ? "" : "s")"
    }

    static func browsePackagesByCategory(_ count: Int) -> String {
        if isRussian {
            return "Просматривайте \(packagesCount(count)) по категориям или используйте поиск выше."
        }
        return "Browse \(count) package\(count == 1 ? "" : "s") by category, or search above."
    }

    static var activeLanguage: String {
        let preferred = Bundle.module.preferredLocalizations.first
            ?? Bundle.main.preferredLocalizations.first
            ?? Locale.preferredLanguages.first
            ?? Locale.autoupdatingCurrent.identifier
        return preferred.lowercased().hasPrefix("ru") ? "ru" : "en"
    }

    static var isRussian: Bool { activeLanguage == "ru" }

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

    static func brewOperationsRunning(_ count: Int) -> String {
        if isRussian {
            return "\(count) \(ruPlural(count, one: "операция brew выполняется", few: "операции brew выполняются", many: "операций brew выполняется"))"
        }
        return "\(count) brew operation\(count == 1 ? "" : "s") running"
    }

    static func githubAction(_ action: String) -> String {
        if !isRussian { return action }
        switch action {
        case "Star": return "Звезда"
        case "Watch": return "Отслеживание"
        default: return action
        }
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

    static func catalogStaleBanner(age: String) -> String {
        if isRussian {
            let when = age == string("date.today") ? "сегодня" : "\(age) назад"
            return "Каталог обновлялся \(when). Новые пакеты и сведения об устаревании могут отсутствовать."
        }
        return "Catalog is \(age). Newer packages and deprecations may be missing."
    }

    static func shortElapsed(seconds: Int) -> String {
        if isRussian {
            if seconds < 60 { return "\(seconds) с" }
            if seconds < 3600 { return "\(seconds / 60) мин." }
            return "\(seconds / 3600) ч"
        }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
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
            let findingWord = ruPlural(findings, one: "запись", few: "записи", many: "записей")
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
            return "Вы отметили звёздочкой \(starred) из \(total) \(packageWord) с домашней страницей на GitHub."
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

    static func activityNotificationBody(label: String, succeeded: Bool) -> String {
        if !isRussian {
            return succeeded ? englishCompletedActivityLabel(label) : "Failed: \(label)"
        }
        if succeeded {
            return russianCompletedActivityLabel(label) ?? russianActivityLabel(label)
        }
        return "Ошибка: \(russianActivityLabel(label))"
    }

    static func activityFailureTitle(for label: String) -> String {
        if !isRussian {
            if label.hasPrefix("Upgrading ") { return "Upgrade failed" }
            if label.hasPrefix("Installing ") { return "Install failed" }
            if label.hasPrefix("Uninstalling ") { return "Uninstall failed" }
            return "\(label) failed"
        }
        if label.hasPrefix("Upgrading ") { return "Не удалось обновить" }
        if label.hasPrefix("Installing ") { return "Не удалось установить" }
        if label.hasPrefix("Uninstalling ") { return "Не удалось удалить" }
        if label.hasPrefix("Adopting ") { return "Не удалось взять под управление" }
        if label.hasPrefix("Reinstalling ") { return "Не удалось переустановить" }
        if label.hasPrefix("Force-removing ") { return "Не удалось принудительно удалить" }
        if label.hasPrefix("Start ") { return "Не удалось запустить службу" }
        if label.hasPrefix("Stop ") { return "Не удалось остановить службу" }
        if label.hasPrefix("Restart ") { return "Не удалось перезапустить службу" }
        return "Не удалось выполнить: \(russianActivityLabel(label))"
    }

    static func progressLabel(_ p: JobProgress) -> String {
        if !isRussian {
            var s = p.phase
            if !p.package.isEmpty { s += " \(p.package)" }
            if let total = p.total { s += " (\(p.current) of \(total))" }
            return s
        }
        let phase: String
        switch p.phase {
        case "Downloading": phase = "Загрузка"
        case "Fetching": phase = "Загрузка"
        case "Pouring": phase = "Распаковка"
        case "Installing": phase = "Установка"
        case "Upgrading": phase = "Обновление"
        default: phase = p.phase
        }
        var s = phase
        if !p.package.isEmpty { s += " \(p.package)" }
        if let total = p.total { s += " (\(p.current) из \(total))" }
        return s
    }

    static func packageKind(_ kind: InstalledPackage.Kind) -> String {
        if !isRussian { return kind.rawValue }
        return kind == .formula ? "формула" : "cask-пакет"
    }

    private static func englishCompletedActivityLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "Installing ", with: "Installed ")
            .replacingOccurrences(of: "Upgrading ", with: "Upgraded ")
            .replacingOccurrences(of: "Uninstalling ", with: "Uninstalled ")
    }

    private static func englishActivityDisplayLabel(_ job: ActivityJob) -> String {
        switch job.status {
        case .running:   return job.label
        case .succeeded: return englishCompletedActivityLabel(job.label)
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
        if let value = label.removingPrefix("Upgrading "),
           let countText = value.removingSuffix(" packages"),
           let count = Int(countText) {
            return "Обновляем \(count) \(ruPlural(count, one: "пакет", few: "пакета", many: "пакетов"))"
        }
        if let name = label.removingPrefix("Installing ") { return "Устанавливаем \(name)" }
        if let name = label.removingPrefix("Upgrading ") { return "Обновляем \(name)" }
        if let name = label.removingPrefix("Uninstalling ") { return "Удаляем \(name)" }
        if let name = label.removingPrefix("Adopting ") { return "Берём под управление \(name)" }
        if let name = label.removingPrefix("Reinstalling ") { return "Переустанавливаем \(name)" }
        if let name = label.removingPrefix("Force-removing ") { return "Принудительно удаляем \(name)" }
        if let name = label.removingPrefix("Start ") { return "Запускаем службу \(name)" }
        if let name = label.removingPrefix("Stop ") { return "Останавливаем службу \(name)" }
        if let name = label.removingPrefix("Restart ") { return "Перезапускаем службу \(name)" }
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
        if let value = label.removingPrefix("Upgrading "),
           let countText = value.removingSuffix(" packages"),
           let count = Int(countText) {
            return "Обновлено \(count) \(ruPlural(count, one: "пакет", few: "пакета", many: "пакетов"))"
        }
        if let name = label.removingPrefix("Installing ") { return "Установлено \(name)" }
        if let name = label.removingPrefix("Upgrading ") { return "Обновлено \(name)" }
        if let name = label.removingPrefix("Uninstalling ") { return "Удалено \(name)" }
        if let name = label.removingPrefix("Adopting ") { return "Взято под управление \(name)" }
        if let name = label.removingPrefix("Reinstalling ") { return "Переустановлено \(name)" }
        if let name = label.removingPrefix("Force-removing ") { return "Принудительно удалено \(name)" }
        if let name = label.removingPrefix("Start ") { return "Служба \(name) запущена" }
        if let name = label.removingPrefix("Stop ") { return "Служба \(name) остановлена" }
        if let name = label.removingPrefix("Restart ") { return "Служба \(name) перезапущена" }
        if let label = label.removingPrefix("Dumping Brewfile: ") { return "Brewfile создан: \(label)" }
        if let label = label.removingPrefix("Restoring ") { return "Восстановлено \(label)" }
        return nil
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    func removingSuffix(_ suffix: String) -> String? {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : nil
    }
}
