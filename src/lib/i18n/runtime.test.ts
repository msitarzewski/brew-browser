import { describe, expect, it } from "vitest";

import { formatCatalogSource, formatPackageKind, resolveLocalePreference } from "./messages";
import { translateText } from "./runtime";

describe("Russian runtime localization", () => {
  it("keeps English as the default locale", () => {
    expect(translateText("Dashboard")).toBe("Dashboard");
  });

  it("resolves system locale to Russian only for Russian systems", () => {
    expect(resolveLocalePreference("system", ["ru-RU", "en-US"])).toBe("ru");
    expect(resolveLocalePreference("system", ["en-US"])).toBe("en");
    expect(resolveLocalePreference("ru", ["en-US"])).toBe("ru");
  });

  it("formats catalog source labels without changing wire values", () => {
    expect(formatCatalogSource("bundled", "ru")).toBe("встроенный");
    expect(formatCatalogSource("user-refreshed", "ru")).toBe("обновлён пользователем");
    expect(formatCatalogSource("user-refreshed", "en")).toBe("user-refreshed");
  });

  it("formats package kind badges without changing package identifiers", () => {
    expect(formatPackageKind("formula", "ru")).toBe("формула");
    expect(formatPackageKind("cask", "ru")).toBe("cask-пакет");
    expect(formatPackageKind("cask", "en")).toBe("cask");
  });

  it("translates exact UI labels", () => {
    expect(translateText("Dashboard", "ru")).toBe("Сводка");
    expect(translateText("Settings", "ru")).toBe("Настройки");
    expect(translateText("Scan all packages", "ru")).toBe("Проверить все пакеты");
    expect(translateText("Search packages…", "ru")).toBe("Поиск пакетов…");
  });

  it("uses Russian plural categories for package counts", () => {
    expect(translateText("1 package", "ru")).toBe("1 пакет");
    expect(translateText("2 packages", "ru")).toBe("2 пакета");
    expect(translateText("5 packages", "ru")).toBe("5 пакетов");
    expect(translateText("21 packages", "ru")).toBe("21 пакет");
  });

  it("localizes dashboard runtime labels", () => {
    expect(translateText("+ 42 more in Library →", "ru")).toBe("Ещё 42 в Библиотеке →");
    expect(translateText("58 on request", "ru")).toBe("58 вручную");
    expect(translateText("7 casks", "ru")).toBe("7 cask-пакетов");
    expect(translateText("3.79 GB total", "ru")).toBe("всего 3.79 GB");
    expect(translateText("Download cache", "ru")).toBe("Кэш загрузок");
    expect(translateText("updates available", "ru")).toBe("доступны обновления");
    expect(translateText("Catalog:", "ru")).toBe("Каталог:");
    expect(translateText("(bundled)", "ru")).toBe("(встроенный)");
    expect(translateText("(user-refreshed)", "ru")).toBe("(обновлён пользователем)");
  });

  it("localizes activity labels without changing package tokens", () => {
    expect(translateText("Installing ripgrep", "ru")).toBe("Устанавливаем ripgrep");
    expect(translateText("Upgrading 22 packages", "ru")).toBe("Обновляем 22 пакета");
    expect(translateText("Force-removing postgres@16", "ru")).toBe("Принудительно удаляем postgres@16");
  });

  it("leaves stable commands and unknown package text alone", () => {
    expect(translateText("brew upgrade --cask firefox", "ru")).toBe("brew upgrade --cask firefox");
    expect(translateText("homebrew/core/wget", "ru")).toBe("homebrew/core/wget");
  });
});
