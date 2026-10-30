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
// SPOKEN POINTER (2026-10-26): when a check finds an update, AVM says so
// once, briefly, and says where the window is. The prompt stays Sparkle's
// own window, read at the user's pace, as above; the announcement exists
// because that window can open unnoticed, behind the dashboard or while
// Windows has the keyboard, and a background check has no other cue.
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

    /// Sparkle holds its delegate weakly, so the updater keeps it.
    private let announcer = UpdateAnnouncer()

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: announcer,
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

/// Says that an update was found and where its window is (header).
final class UpdateAnnouncer: NSObject, SPUUpdaterDelegate {
    /// The helper exits before the new AVM starts (2026-10-28, code
    /// review): it used to keep running for its idle grace period, and
    /// the new AVM talked to it.
    ///
    /// Only once AVM is really quitting (2026-10-28, fourth audit): Sparkle
    /// calls this before it asks AVM to quit, and stopping the helper here
    /// took every USB, Bluetooth and Windows-keyboard device out of the
    /// running machines before the question "Windows is still running.
    /// Quit AVM?" was even asked; Cancel left them without their devices.
    /// applicationWillTerminate asks the helper to exit, after the
    /// machines have been shut down or saved.
    nonisolated(unsafe) static var relaunchingForUpdate = false
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        NSLog("AVM: Updates — relaunching; the USB helper exits when AVM quits.")
        Self.relaunchingForUpdate = true
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            let inGuest = FocusLockManager.shared?.isLocked ?? false
            AVMLog.write("AVM: Updates — found version \(version).")
            Announcer.shared.announce(
                inGuest
                    ? "AVM \(version) is available. Leave \(FocusLockManager.shared?.guestName ?? "the machine") to read the update window."
                    : "AVM \(version) is available. The update window is open.",
                tone: .info
            )
        }
    }
}

// MARK: - What's New, after an update (2026-10-30)
//
// The user's request: easy-to-read release notes on the first launch after
// an update. A small window, "What's New in AVM 0.1.4", a heading per
// version and a few plain lines each, read by VoiceOver as it opens; OK (or
// Return) closes it. It covers every version since the one last run, and
// is in the Help menu too. Not while the keyboard is in a machine: it
// waits until the user is back on the Mac.
//
// Every release adds its entry at the top of ReleaseNotes.all;
// Tools/build-installer.sh refuses a version without one.

import AppKit
import SwiftUI

struct ReleaseNote {
    let version: String
    let changes: [String]
}

@MainActor
enum ReleaseNotes {
    /// Newest first.
    static let all: [ReleaseNote] = [
        ReleaseNote(version: "0.1.4", changes: [
            "The dashboard lists your virtual machines in a table: Name, Status, System, Cores, Memory, Disk and Drive. Choose one with the arrow keys. Return starts it, or enters it when it's running. VO-Shift-M opens its other actions, and its buttons are below the table.",
            "Each running virtual machine is in Command-Tab under its own name. Switch to it and your keyboard goes straight in. Control-Command-Escape brings you back.",
            "Each app open in Windows is in Command-Tab too. Switch to one and press Command-Shift-E to type in it. Keep in Dock and Applications keeps one there, and opening it starts AVM and Windows if needed.",
            "Settings has Trackpad and Mouse: turn it off so a stray touch can't move or click in the machine.",
            "With AVM opening at login and a machine starting with it, AVM comes to the front, so the machine gets your keyboard.",
            "After an update, this window says what's new. It's in the Help menu too.",
        ]),
    ]

    private static let seenKey = "AVMLastVersionSeen"
    private static var window: NSWindow?

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The notes after `old` (all of them for nil), up to this version.
    static func since(_ old: String?) -> [ReleaseNote] {
        all.filter { note in
            (old.map { note.version.compare($0, options: .numeric) == .orderedDescending } ?? true)
                && note.version.compare(current, options: .numeric) != .orderedDescending
        }
    }

    /// At launch: once after an update, the notes since the version last
    /// run. Nothing after a first install. A copy updated from a version
    /// before this window, which stored no version, gets this version's
    /// notes when it has machines set up.
    static func showIfUpdated() {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: seenKey)
        guard last != current else { return }
        // A moment for the machine list to load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            defaults.set(current, forKey: seenKey)
            let notes: [ReleaseNote]
            if let last {
                notes = since(last)
            } else if VMStore.shared?.configurations.isEmpty == false {
                notes = all.filter { $0.version == current }
            } else {
                notes = []
            }
            guard !notes.isEmpty else { return }
            AVMLog.write("AVM: updated from \(last ?? "an earlier version") to \(current); showing what's new")
            showWhenOnTheMac(notes)
        }
    }

    /// This version's notes and the two before, for the Help menu and the
    /// accessibility audit.
    static var recent: [ReleaseNote] { Array(since(nil).prefix(3)) }

    static func showRecent() { show(recent) }

    private static func showWhenOnTheMac(_ notes: [ReleaseNote]) {
        guard FocusLockManager.shared?.isLocked != true else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showWhenOnTheMac(notes) }
            return
        }
        show(notes)
    }

    static func show(_ notes: [ReleaseNote]) {
        guard !notes.isEmpty else { return }
        window?.close()
        let title = notes.count == 1 ? "What's New in AVM \(notes[0].version)" : "What's New in AVM"
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: WhatsNewView.size),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: WhatsNewView(title: title, notes: notes) { window?.close() })
        panel.center()
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

/// The notes: a heading per version, a line per change, and OK.
struct WhatsNewView: View {
    static let size = NSSize(width: 540, height: 460)
    let title: String
    let notes: [ReleaseNote]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(notes, id: \.version) { note in
                        VStack(alignment: .leading, spacing: 10) {
                            if notes.count > 1 {
                                Text("AVM \(note.version)")
                                    .font(.title3.bold())
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(note.changes, id: \.self) { change in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").accessibilityHidden(true)
                                    Text(change).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("OK", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height)
    }
}
