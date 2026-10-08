// swift-tools-version:6.0
// iRufus — SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PackageDescription

// The Rust engine is built by scripts/build-engine.sh into this directory
// (a universal static library when building for both architectures).
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let engineLibDir = ProcessInfo.processInfo.environment["IRUFUS_ENGINE_LIB_DIR"]
    ?? "\(packageDir)/../engine/target/irufus"

let engineLinker: [LinkerSetting] = [
    .unsafeFlags(["-L", engineLibDir]),
    .linkedFramework("CoreFoundation"),
    .linkedLibrary("iconv"),
]

let package = Package(
    name: "iRufus",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iRufus", targets: ["iRufus"]),
    ],
    targets: [
        .systemLibrary(name: "CIrufus", path: "Sources/CIrufus"),
        .target(
            name: "IrufusCore",
            dependencies: ["CIrufus"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: engineLinker + [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "iRufus",
            dependencies: ["IrufusCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: engineLinker
        ),
        // Checks for IrufusCore, run with `swift run IrufusCoreChecks` (see Harness.swift).
        .executableTarget(
            name: "IrufusCoreChecks",
            dependencies: ["IrufusCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: engineLinker
        ),
    ]
)
