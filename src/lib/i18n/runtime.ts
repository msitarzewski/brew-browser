import { DEFAULT_LOCALE, messages, ruPlural, type Locale } from "./messages";

type Replacement = (match: RegExpMatchArray) => string;

const ATTRIBUTES = ["aria-label", "title", "placeholder", "alt"] as const;
const SKIP_TAGS = new Set(["CODE", "KBD", "PRE", "SAMP", "SCRIPT", "STYLE", "TEXTAREA"]);

const patterns: Array<[RegExp, Replacement]> = [
  [/^Theme: (Light|Dark|System)$/u, (m) => `Тема: ${translateText(m[1])}`],
  [/^updates available$/u, () => "доступны обновления"],
  [/^Catalog:$/u, () => "Каталог:"],
  [/^\(bundled\)$/u, () => "(встроенный)"],
  [/^(\d+) days old$/u, (m) => {
    const n = Number(m[1]);
    return `${n} ${ruPlural(n, "день", "дня", "дней")}`;
  }],
  [/^(\d+) day old$/u, (m) => `${m[1]} день`],
  [/^today$/u, () => "сегодня"],
  [/^(\d+) min$/u, (m) => `${m[1]} мин`],
  [/^(\d+) minutes$/u, (m) => `${m[1]} мин`],
  [/^(\d+) running · (\d+) total$/u, (m) => {
    const running = Number(m[1]);
    const total = Number(m[2]);
    return `${running} ${ruPlural(running, "служба запущена", "службы запущены", "служб запущено")} · всего ${total}`;
  }],
  [/^(\d+) brew operations? running$/u, (m) => {
    const n = Number(m[1]);
    return `${n} ${ruPlural(n, "операция brew выполняется", "операции brew выполняются", "операций brew выполняется")}`;
  }],
  [/^(\d+) packages? with known vulnerabilities$/u, (m) => {
    const n = Number(m[1]);
    return `${n} ${ruPlural(n, "пакет с известными уязвимостями", "пакета с известными уязвимостями", "пакетов с известными уязвимостями")}`;
  }],
  [/^(\d+) vulnerable packages?$/u, (m) => {
    const n = Number(m[1]);
    return `${n} ${ruPlural(n, "уязвимый пакет", "уязвимых пакета", "уязвимых пакетов")}`;
  }],
  [/^(\d+) of (\d+) selected$/u, (m) => `Выбрано ${m[1]} из ${m[2]}`],
  [/^(\d+) package(s)?$/u, (m) => {
    const n = Number(m[1]);
    return `${n} ${ruPlural(n, "пакет", "пакета", "пакетов")}`;
  }],
  [/^\+ (\d+) more in Library(?: →)?$/u, (m) => `Ещё ${m[1]} в Библиотеке${m[0].endsWith("→") ? " →" : ""}`],
  [/^Upgrade all \((\d+)\)$/u, (m) => `Обновить всё (${m[1]})`],
  [/^Catalog: (.+)$/u, (m) => `Каталог: ${m[1]}`],
  [/^Catalog is (.+)\. Newer packages and deprecations may be missing\.$/u, (m) => (
    `Каталог устарел: ${m[1]}. Новые пакеты и сведения об устаревании могут отсутствовать.`
  )],
  [/^Catalog stale-banner threshold: (\d+) days$/u, (m) => {
    const n = Number(m[1]);
    return `Порог предупреждения об устаревшем каталоге: ${n} ${ruPlural(n, "день", "дня", "дней")}`;
  }],
  [/^Trending cache TTL: (\d+) min$/u, (m) => `TTL кэша трендов: ${m[1]} мин`],
  [/^Keep last (\d+) completed jobs$/u, (m) => {
    const n = Number(m[1]);
    return `Хранить ${n} ${ruPlural(n, "последнюю завершённую задачу", "последние завершённые задачи", "последних завершённых задач")}`;
  }],
  [/^Lines per job: (\d+)$/u, (m) => `Строк на задачу: ${m[1]}`],
  [/^Last checked: (.+)$/u, (m) => `Последняя проверка: ${m[1]}`],
  [/^Last scan: (.+)$/u, (m) => `Последняя проверка: ${m[1]}`],
  [/^frees ~(.+)$/u, (m) => `освободит ~${m[1]}`],
  [/^(.+) total$/u, (m) => `всего ${m[1]}`],
  [/^(\d+) on request$/u, (m) => `${m[1]} вручную`],
  [/^(\d+) as dependency$/u, (m) => `${m[1]} как зависимости`],
  [/^(\d+) pinned$/u, (m) => `${m[1]} закреплено`],
  [/^(\d+) formulae$/u, (m) => {
    const n = Number(m[1]);
    return `${n} ${ruPlural(n, "формула", "формулы", "формул")}`;
  }],
  [/^(\d+) casks$/u, (m) => {
    const n = Number(m[1]);
    return `${n} ${ruPlural(n, "cask-пакет", "cask-пакета", "cask-пакетов")}`;
  }],
  [/^Formulae \(Cellar\)$/u, () => "Формулы (Cellar)"],
  [/^Casks \(Caskroom\)$/u, () => "Cask-пакеты (Caskroom)"],
  [/^Logs \(var\/log\)$/u, () => "Логи (var/log)"],
  [/^Download cache$/u, () => "Кэш загрузок"],
  [/^(\d+) finding(s)? across (\d+) of (\d+) installed packages(.*)$/u, (m) => {
    const findings = Number(m[1]);
    const packages = Number(m[3]);
    return `${findings} ${ruPlural(findings, "результат проверки", "результата проверки", "результатов проверки")} у ${packages} ${ruPlural(packages, "пакета", "пакетов", "пакетов")} из ${m[4]} установленных${m[5] ?? ""}`;
  }],
  [/^No advisories as of the last scan \((.+)\)\.$/u, (m) => `На момент последней проверки (${m[1]}) записей об уязвимостях нет.`],
  [/^No advisories as of the last scan — re-scan to confirm$/u, () => "На момент последней проверки записей об уязвимостях нет — проверьте ещё раз для подтверждения"],
  [/^Patched in (.+)$/u, (m) => `Исправлено в ${m[1]}`],
  [/^License mismatch — brew: (.+), GitHub: (.+)$/u, (m) => `Лицензии не совпадают — brew: ${m[1]}, GitHub: ${m[2]}`],
  [/^Blocked by Offline Mode\. Disable in Settings → Network\.$/u, () => "Заблокировано офлайн-режимом. Отключите его в разделе «Настройки → Сеть»."],
  [/^Backend not available: (.+)$/u, (m) => `Бэкенд недоступен: ${m[1]}`],
  [/^Failed to load categories: (.+)$/u, (m) => `Не удалось загрузить категории: ${m[1]}`],
  [/^Nothing matches the (.+) filter\.$/u, (m) => `По фильтру «${translateText(m[1])}» ничего не найдено.`],
  [/^Nothing in this category\.$/u, () => "В этой категории пока ничего нет."],
  [/^The bundled package catalog couldn't be loaded\.$/u, () => "Не удалось загрузить встроенный каталог пакетов."],
  [/^Browse (\d+) packages by category, or search above\.$/u, (m) => {
    const n = Number(m[1]);
    return `Просматривайте ${n} ${ruPlural(n, "пакет", "пакета", "пакетов")} по категориям или используйте поиск выше.`;
  }],
  [/^Pinned packages are not upgraded by brew\. Unpin from the package detail page\.$/u, () => "Закреплённые пакеты не обновляются через brew. Открепите пакет в его карточке."],
  [/^Pinned packages are not upgraded by brew\. Unpin with `brew unpin <name>`\.$/u, () => "Закреплённые пакеты не обновляются через brew. Открепите их командой `brew unpin <name>`."],
  [/^A newer version of brew-browser is available — click to update$/u, () => "Доступна новая версия brew-browser — нажмите, чтобы обновить"],
  [/^Homebrew status unknown — (.+)$/u, (m) => `Статус Homebrew неизвестен — ${m[1]}`],
  [/^Homebrew not found on PATH\.$/u, () => "Homebrew не найден в PATH."],
  [/^Homebrew is installed\.$/u, () => "Homebrew установлен."],
  [/^Homebrew analytics (enabled|disabled)$/u, (m) => `Аналитика Homebrew ${m[1] === "enabled" ? "включена" : "отключена"}`],
  [/^brew not found$/u, () => "brew не найден"],
  [/^prefix (.+)$/u, (m) => `prefix ${m[1]}`],
  [/^stored in (.+)$/iu, (m) => `хранится в ${m[1]}`],
  [/^source: (.+)$/u, (m) => `источник: ${m[1]}`],
  [/^user: (.+)$/u, (m) => `пользователь: ${m[1]}`],
  [/^Installing (.+)$/u, (m) => `Устанавливаем ${m[1]}`],
  [/^Installed (.+)$/u, (m) => `Установлено: ${m[1]}`],
  [/^Upgrading all packages$/u, () => "Обновляем все пакеты"],
  [/^Upgrading (\d+) packages?$/u, (m) => {
    const n = Number(m[1]);
    return `Обновляем ${n} ${ruPlural(n, "пакет", "пакета", "пакетов")}`;
  }],
  [/^Upgrading (.+)$/u, (m) => `Обновляем ${m[1]}`],
  [/^Upgraded (\d+) packages?$/u, (m) => {
    const n = Number(m[1]);
    return `Обновлено ${n} ${ruPlural(n, "пакет", "пакета", "пакетов")}`;
  }],
  [/^Uninstalling (.+)$/u, (m) => `Удаляем ${m[1]}`],
  [/^Uninstalled (.+)$/u, (m) => `Удалено: ${m[1]}`],
  [/^Adopting (.+)$/u, (m) => `Берём под управление ${m[1]}`],
  [/^Reinstalling (.+)$/u, (m) => `Переустанавливаем ${m[1]}`],
  [/^Force-removing (.+)$/u, (m) => `Принудительно удаляем ${m[1]}`],
  [/^Updating Homebrew taps$/u, () => "Обновляем tap-репозитории Homebrew"],
  [/^Running brew doctor$/u, () => "Запускаем brew doctor"],
  [/^(.+) is already installed outside Homebrew\.$/u, (m) => `${m[1]} уже установлен вне Homebrew.`],
  [/^(.+) is still required by another installed package\.$/u, (m) => `${m[1]} всё ещё требуется другому установленному пакету.`],
  [/^Refusing to open (.+) URL$/u, (m) => `Не открываем URL со схемой ${m[1]}`],
];

function shouldSkip(node: Node): boolean {
  const el = node.nodeType === Node.ELEMENT_NODE ? node as Element : node.parentElement;
  const closest = el?.closest("[data-i18n-skip], code, kbd, pre, samp, script, style, textarea");
  if (closest) return true;
  return Boolean(el && SKIP_TAGS.has(el.tagName));
}

function preserveOuterWhitespace(source: string, replacement: string): string {
  const match = source.match(/^(\s*)([\s\S]*?)(\s*)$/u);
  if (!match) return replacement;
  return `${match[1]}${replacement}${match[3]}`;
}

export function translateText(source: string, locale: Locale = DEFAULT_LOCALE): string {
  if (locale !== "ru") return source;
  const compact = source.replace(/\s+/gu, " ").trim();
  if (!compact) return source;
  const exact = (messages[locale] as Record<string, string>)[compact];
  if (exact) return preserveOuterWhitespace(source, exact);
  for (const [pattern, replace] of patterns) {
    const match = compact.match(pattern);
    if (match) return preserveOuterWhitespace(source, replace(match));
  }
  return source;
}

function localizeTextNode(node: Text, locale: Locale): void {
  if (shouldSkip(node)) return;
  const next = translateText(node.data, locale);
  if (next !== node.data) node.data = next;
}

function localizeElementAttributes(el: Element, locale: Locale): void {
  if (shouldSkip(el)) return;
  for (const attr of ATTRIBUTES) {
    const value = el.getAttribute(attr);
    if (!value) continue;
    const next = translateText(value, locale);
    if (next !== value) el.setAttribute(attr, next);
  }
}

function walk(root: Node, locale: Locale): void {
  if (root.nodeType === Node.TEXT_NODE) {
    localizeTextNode(root as Text, locale);
    return;
  }
  if (root.nodeType !== Node.ELEMENT_NODE && root.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) return;
  if (root.nodeType === Node.ELEMENT_NODE) localizeElementAttributes(root as Element, locale);
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (node.nodeType === Node.TEXT_NODE) {
      localizeTextNode(node as Text, locale);
    } else if (node.nodeType === Node.ELEMENT_NODE) {
      localizeElementAttributes(node as Element, locale);
    }
  }
}

export function startRuntimeLocalization(locale: Locale = DEFAULT_LOCALE): () => void {
  if (typeof document === "undefined") return () => {};

  document.documentElement.lang = locale;
  if (locale === "en") return () => {};
  walk(document.body, locale);

  const observer = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      if (mutation.type === "characterData") {
        localizeTextNode(mutation.target as Text, locale);
      } else if (mutation.type === "attributes" && mutation.target instanceof Element) {
        localizeElementAttributes(mutation.target, locale);
      } else {
        for (const node of mutation.addedNodes) walk(node, locale);
      }
    }
  });

  observer.observe(document.body, {
    attributes: true,
    attributeFilter: [...ATTRIBUTES],
    characterData: true,
    childList: true,
    subtree: true,
  });

  return () => observer.disconnect();
}
