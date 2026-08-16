// AVMUpdater.swift
// AVM — Accessible Virtual Machine
//
// Sparkle updater ownership (ADDED 2026-08-16, Handoff 43 session).
//
// WHY SPARKLE, not a custom checker: the update prompt is standard AppKit
// UI — real windows, real buttons, native VoiceOver focus and re-reading at
// the user's own pace. That is the elegant VoiceOver path (settled
// 2026-08-16: self-voicing is only for moments with no UI to land focus on,
// like a QEMU crash mid-session; an update prompt is not one of those).
// Sparkle also gives atomic replace-and-relaunch, so testers never touch a
// DMG again after the first Sparkle-carrying build.
//
// CONFIGURATION OF RECORD (all three settled 2026-08-16):
//   - Feed: SUFeedURL in Info.plist → appcast.xml at the repo root on main,
//     served via raw.githubusercontent.com (repo is the host; a release is
//     a commit). raw caching means a new release can take ~5 minutes to
//     become visible — harmless for launch-time checks.
//   - Signing: SUPublicEDKey in Info.plist. The private key lives in the
//     login Keychain with a file backup in iCloud Drive/AVM-keys. It NEVER
//     enters the repo.
//   - Consent: SUEnableAutomaticChecks is deliberately ABSENT from
//     Info.plist, so Sparkle shows its one-time "check automatically?"
//     consent dialog on first launch. Automatic DOWNLOAD stays off
//     (Sparkle default): launch checks are silent when current — no sound,
//     no dialog, nothing to narrate for a non-event — and only produce UI
//     when an update actually exists. The manual menu check DOES show
//     "you're up to date", because that time the user asked.
//
// startingUpdater: true — the updater starts with the app and owns the
// launch-time check schedule. There is no reason to defer: recovery paths
// that must precede user actions (Caps Lock) run in
// applicationDidFinishLaunching, and Sparkle's first consent dialog cannot
// fire before the run loop is up anyway.
//
// canCheckForUpdates is republished so the menu item can dim while a check
// or install is already in flight — reactive dimming is fine HERE (unlike
// the parked VM-state menu dimming) because Sparkle itself provides the
// observable; no new app-level state model is needed.
//
// import Combine is REQUIRED, not decorative: @Published, assign(to:), and
// ObservableObject are Combine symbols, and this file uses all three.
// Omitting it fails the build (proven 2026-08-16, first build of this file).
import Foundation
import SwiftUI
import Combine
import Sparkle

@MainActor
final class AVMUpdater: ObservableObject {
    /// The one Sparkle controller for the app. Standard user driver =
    /// standard AppKit alerts = native VoiceOver behavior.
    private let controller: SPUStandardUpdaterController

    /// Mirrors Sparkle's own gate for whether a user-initiated check can
    /// start now. Drives the menu item's disabled state.
    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Menu-invoked check. Shows Sparkle's standard UI in every outcome,
    /// including "you're up to date" — the user asked, so silence would be
    /// a bug. The log line records the invocation; Sparkle's own UI carries
    /// the outcome. Privacy check: names an AVM menu command only.
    func checkForUpdates() {
        AVMLog.write("AVM: Check for Updates menu — invoking Sparkle user-initiated check.")
        controller.checkForUpdates(nil)
    }
}
