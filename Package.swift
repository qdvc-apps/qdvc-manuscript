// swift-tools-version: 5.10
//
// QDVC Manuscript for macOS — a calm word processor for writing a research
// article: one sentence per line in Git-friendly Markdown, sections in
// numbered files, pandoc-mustache variables, figures and tables with
// self-renumbering cross-references, citations from QDVC Bibliotheca,
// Focus mode and topic-sentence views.
//
// No dependencies, and nothing in the app touches the network
// (docs/MAINTENANCE.md §Network).
//
// Build:   swift build            (or open this folder in Xcode)
// Test:    swift test
// Bundle:  scripts/build-app.sh   (ad-hoc signed, sandboxed .app; no Apple account needed)

import PackageDescription

var products: [Product] = [
    .library(name: "ManuscriptCore", targets: ["ManuscriptCore"]),
]
var targets: [Target] = [
    // Pure model layer: Foundation only (its own YAML, Markdown, ZIP and
    // DOCX code), no AppKit/SwiftUI, unit-testable on Linux too.
    .target(name: "ManuscriptCore"),
    .testTarget(
        name: "ManuscriptCoreTests",
        dependencies: ["ManuscriptCore"]
    ),
]

#if os(macOS)
// The SwiftUI/AppKit front-end. Declared on macOS only, so the core and its
// tests also build with a Linux Swift toolchain (docs/MAINTENANCE.md).
products.insert(.executable(name: "QDVCManuscript", targets: ["QDVCManuscript"]), at: 0)
targets.insert(.executableTarget(name: "QDVCManuscript", dependencies: ["ManuscriptCore"]), at: 1)
#endif

let package = Package(
    name: "QDVCManuscript",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
