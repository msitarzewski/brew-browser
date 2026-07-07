// swift-tools-version:6.2
import PackageDescription

// brew-browser native — SwiftUI + Liquid Glass (macOS 26 Tahoe).
//
// Apple's intended multi-module shape: a thin `@main` executable
// (`BrewBrowser`) over a `BrewBrowserKit` library that holds all views,
// models, and services. The library layout is what makes SwiftUI `#Preview`
// (and Xcode's RenderPreview) work — previewing an *executable* target
// requires ENABLE_DEBUG_DYLIB, which is only settable in an .xcodeproj; a
// library target previews without it.
//
// Still 100% SwiftPM (no .xcodeproj). Built with `swift build`; the produced
// `BrewBrowser` executable is wrapped into a launchable .app by build-app.sh.
let package = Package(
    name: "BrewBrowser",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        // Exposing the library as a product makes SwiftPM/Xcode generate a
        // dedicated `BrewBrowserKit` scheme. SwiftUI previews (RenderPreview)
        // build against THAT library scheme — previewing via the executable
        // scheme fails with DebugDylibNotEnabled (.xcodeproj-only setting).
        .library(name: "BrewBrowserKit", targets: ["BrewBrowserKit"])
    ],
    dependencies: [
        // Sparkle 2 — the standard self-updater for non-MAS macOS apps. Powers
        // the native build's in-app update (Settings → Updates + the titlebar
        // "update available" pill), mirroring the Tauri updater. Sole sanctioned
        // third-party dependency; everything else is stock SwiftUI/AppKit.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Thin executable: just the @main App entry, importing BrewBrowserKit.
        .executableTarget(
            name: "BrewBrowser",
            dependencies: ["BrewBrowserKit"],
            path: "Sources/BrewBrowser",
            resources: [
                .process("Resources/Localizable.xcstrings")
            ]
        ),
        // Library: all views, AppModel, and the brew/vulns/github/trending/
        // enrichment services. Bundled JSON resources live here alongside the
        // `Bundle.module` readers (Categories.swift, Enrichment.swift).
        .target(
            name: "BrewBrowserKit",
            dependencies: [
                // The updater wrapper (UpdaterController.swift) wraps Sparkle's
                // SPUStandardUpdaterController; the views read its @Observable state.
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/BrewBrowserKit",
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/categories.json"),
                .copy("Resources/enrichment.json"),
                // GitHub Octocat mark (vector PDF, Primer/Octicons MIT). Rendered
                // as a template image in the toolbar's "connected" chip.
                .copy("Resources/github-mark.pdf"),
                // App icon, loaded at runtime via Bundle.module to set the Dock
                // icon. Works even for the bare `swift build` / Xcode ⌘R binary
                // (which has no .app bundle Info.plist icon).
                .copy("Resources/AppIcon.icns"),
                // Full Homebrew catalog (gzipped) for the Discover panel —
                // 8.3k formulae + 7.7k casks. Same data the Tauri app bundles
                // (src-tauri/data/catalog); decompressed + parsed at runtime by
                // CatalogService. ~6MB gzipped / ~44MB raw, so kept compressed.
                .copy("Resources/catalog")
            ]
        ),
        // Unit tests for the pure, parity-critical logic — brew output parsing
        // (friendly errors, non-fatal upgrade classification, progress markers),
        // settings Codable contracts, category membership, vulns parsing.
        // `@testable import` exposes the library's internal symbols. Runs with
        // `swift test`; does not affect `swift build` / build-app.sh.
        .testTarget(
            name: "BrewBrowserKitTests",
            dependencies: ["BrewBrowserKit"],
            path: "Tests/BrewBrowserKitTests"
        )
    ]
)
