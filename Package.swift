// swift-tools-version: 6.2
// Package.swift
// AVM — Accessible Virtual Machine
//
// The logic test suite (2026-10-26). The app itself builds from
// AVM.xcodeproj, which needs the UTM sysroot. This package compiles only
// AVM's self-contained logic files, with the app target's own language
// settings, and tests them, so the tests run anywhere: `swift test` on a
// Mac with Xcode, and on every push in GitHub Actions
// (.github/workflows/ci.yml). It builds nothing that ships.

import PackageDescription

/// The same settings as the AVM app target: Swift 5 mode, MainActor by
/// default, approachable concurrency.
let appSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "AVMLogic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "AVMLogic",
            path: ".",
            sources: [
                "AVMLog.swift",
                "Announcer.swift",
                "VM/SHA512Crypt.swift",
                "VM/VMConfiguration.swift",
                "VM/VMStore.swift",
                "AVM/QEMUSavedState.swift",
                "VM/UbuntuInstallPipeline.swift",
                "AVMUSBHelper/StreamSocketCheck.swift",
                "AVM/ScreenReaderInstallers.swift",
                "AVM/WindowsRegion.swift",
                "AVM/WindowsSetupAnswers.swift",
                "AVM/GuestAgent.swift",
                "AVM/SetupReport.swift",
                "AVM/HIDKeyMap.swift",
                "AVM/MacGuestFiles.swift",
                "AVM/MachineArchive.swift",
            ],
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "AVMLogicTests",
            dependencies: ["AVMLogic"],
            path: "Tests/AVMLogicTests",
            swiftSettings: appSettings
        ),
    ],
    swiftLanguageModes: [.v5]
)
