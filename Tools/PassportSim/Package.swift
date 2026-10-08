// swift-tools-version:5.9
// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

// Development tool: a macOS stand-in for the Passport, the device side of the BLE link
// (docs/ble-protocol.md §4-§7), so the app can be tested without the hardware. Run it through
// run.sh (a small .app bundle, so macOS attributes the Bluetooth permission to it).
import PackageDescription

let package = Package(
    name: "PassportSim",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/PocketKit")],
    targets: [
        .executableTarget(
            name: "PassportSim",
            dependencies: [.product(name: "PocketCore", package: "PocketKit"),
                           .product(name: "PocketOpus", package: "PocketKit")],
            path: "Sources/PassportSim",
            exclude: ["Info.plist"]
        )
    ]
)
