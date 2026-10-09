// swift-tools-version:5.9
// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

// Platform-independent pieces of 多多随身: the Passport BLE link codec, voice
// note assembly and upload, reply tracking, and the Opus encoder wrapper.
// Shared by the iOS app and the macOS Passport simulator; tested on the host
// with `swift test`.
import PackageDescription

let package = Package(
    name: "PocketKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PocketCore", targets: ["PocketCore"]),
        .library(name: "PocketOpus", targets: ["PocketOpus"]),
    ],
    dependencies: [
        // DuoDuo's answers are Markdown; parsed here, drawn by the app.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.9.0")),
    ],
    targets: [
        .target(name: "PocketCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        // Built by scripts/build-opus.sh; not tracked.
        .binaryTarget(name: "Opus", path: "Vendor/Opus.xcframework"),
        .target(name: "COpusShim", dependencies: ["Opus"]),
        .target(name: "PocketOpus", dependencies: ["Opus", "COpusShim", "PocketCore"]),
        .testTarget(name: "PocketCoreTests", dependencies: ["PocketCore"]),
        .testTarget(name: "PocketOpusTests", dependencies: ["PocketOpus", "PocketCore"]),
    ]
)
