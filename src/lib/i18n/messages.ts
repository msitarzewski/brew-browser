import en from "./en";
import ru from "./ru";

export type Locale = "en" | "ru";
export type LocalePreference = "system" | Locale;

export const DEFAULT_LOCALE: Locale = "en";
export const DEFAULT_LOCALE_PREFERENCE: LocalePreference = "system";
export const LOCALE_PREFERENCES = ["system", "en", "ru"] as const;

export const messages: Record<Locale, Record<string, string>> = {
  en,
  ru,
};

export const messagesEn: Record<string, string> = en;
export const messagesRu: Record<string, string> = ru;

export function isLocalePreference(value: string | null): value is LocalePreference {
  return value === "system" || value === "en" || value === "ru";
}

export function resolveLocalePreference(
  preference: LocalePreference,
  languages: readonly string[] = typeof navigator === "undefined" ? [] : navigator.languages,
): Locale {
  if (preference !== "system") return preference;
  return languages.some((language) => language.toLowerCase().startsWith("ru")) ? "ru" : DEFAULT_LOCALE;
}
