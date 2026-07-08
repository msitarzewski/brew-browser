import en from "./en";
import ru from "./ru";

export type MessageKey = keyof typeof en;
type MessageCatalog = { [K in MessageKey]: string };
type InterpolationValue = string | number;

export const messages = {
  en,
  ru,
} as const satisfies Record<string, MessageCatalog>;

export type Locale = keyof typeof messages;
export type LocalePreference = "system" | Locale;

export const DEFAULT_LOCALE: Locale = "en";
export const DEFAULT_LOCALE_PREFERENCE: LocalePreference = "system";
export const SUPPORTED_LOCALES = Object.keys(messages) as Locale[];
export const LOCALE_PREFERENCES = ["system", ...SUPPORTED_LOCALES] as const;

export const messagesEn: Record<string, string> = en;
export const messagesRu: Record<string, string> = ru;

export function t(
  key: MessageKey,
  locale: Locale = DEFAULT_LOCALE,
  params: Record<string, InterpolationValue> = {},
): string {
  const template = messages[locale][key] ?? messages.en[key] ?? key;
  return template.replace(/\{([a-zA-Z0-9_]+)\}/gu, (_, name: string) => {
    const value = params[name];
    return value === undefined ? `{${name}}` : String(value);
  });
}

export function ruPlural(n: number, one: string, few: string, many: string): string {
  const mod10 = Math.abs(n) % 10;
  const mod100 = Math.abs(n) % 100;
  if (mod10 === 1 && mod100 !== 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 10 || mod100 >= 20)) return few;
  return many;
}

export function formatBrewOperationsRunning(count: number, locale: Locale): string {
  if (locale === "ru") {
    return `${count} ${ruPlural(count, "операция brew выполняется", "операции brew выполняются", "операций brew выполняется")}`;
  }
  return `${count} brew operation${count === 1 ? "" : "s"} running`;
}

export function formatVulnerablePackages(count: number, locale: Locale): string {
  if (locale === "ru") {
    return `${count} ${ruPlural(count, "уязвимый пакет", "уязвимых пакета", "уязвимых пакетов")}`;
  }
  return `${count} vulnerable package${count === 1 ? "" : "s"}`;
}

export function formatVulnerablePackageLabel(count: number, locale: Locale): string {
  if (locale === "ru") {
    return ruPlural(count, "уязвимый пакет", "уязвимых пакета", "уязвимых пакетов");
  }
  return `vulnerable package${count === 1 ? "" : "s"}`;
}

export function isLocalePreference(value: string | null): value is LocalePreference {
  return value === "system" || (value !== null && value in messages);
}

function localeFromLanguage(language: string): Locale | null {
  const normalized = language.toLowerCase();
  const primary = normalized.split("-")[0];
  return SUPPORTED_LOCALES.find((locale) => locale === normalized || locale === primary) ?? null;
}

export function resolveLocalePreference(
  preference: LocalePreference,
  languages: readonly string[] = typeof navigator === "undefined" ? [] : navigator.languages,
): Locale {
  if (preference !== "system") return preference;
  for (const language of languages) {
    const locale = localeFromLanguage(language);
    if (locale) return locale;
  }
  return DEFAULT_LOCALE;
}
