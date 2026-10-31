// InputMonitoring.swift
// AVM — Accessible Virtual Machine
//
// Input Monitoring, for a device with keys (2026-10-29, the user's APH
// Mantis Q40 sent over Bluetooth: "macOS wouldn't let the helper take the
// device (error 0xe00002e2)"). macOS lets a process open a HID device that
// has a keyboard in it only when Input Monitoring allows it, and for AVM's
// helper it asks that of AVM: tccd attributes the helper to the app around
// it ("Sub:{com.alllisonmeloy.AVM}"). A helper running as root can't be
// asked, so macOS refused it without a word ("TCC deny IOHIDDeviceOpen",
// kIOReturnNotPermitted), and nothing ever listed AVM under Input
// Monitoring for the user to turn on. A keyboard for Windows needs it the
// same way, and so does a braille display whose keys are a keyboard too
// (HIDReportDescriptor.hasKeyboard). A device sent through a USB port
// doesn't: the helper takes the whole USB device there, not its keyboard.
//
// So AVM asks when a device needs it. Its own alert says why and what to
// do, then macOS's own dialog follows the first time (IOHIDRequestAccess),
// which lists AVM under Input Monitoring; once AVM is listed, System
// Settings opens there instead. AVM then waits for it to be turned on, as
// it waits for the helper's approval in Login Items, and carries on. The
// helper stays the judge: once the wait is over the send goes ahead, and a
// refusal is said with what to do. The helper isn't asked while the alert
// is up: a refusal can stay with the helper's process for a while.

import AppKit
import IOKit.hid

@MainActor
enum InputMonitoring {
    /// How an ask ended.
    enum Outcome { case allowed, notNow, gaveUp }

    /// Whether macOS allows AVM now.
    static var isAllowed: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    /// The helper's refusal for want of it: its "macOS wouldn't let the
    /// helper take …" line ends with the code (BluetoothHold, KeyboardHold).
    nonisolated static func refusedHelper(_ detail: String) -> Bool {
        detail.contains("0xe00002e2")   // kIOReturnNotPermitted
    }

    /// Where to turn it on, for a spoken line.
    static let steps = "In System Settings, under Privacy & Security, then Input Monitoring, turn on AVM."

    /// Asks under way, with the alert up or waiting after it. One alert at a
    /// time, as the Login Items one: a second ask meanwhile (a keyboard for
    /// Windows at a start, and a Bluetooth send) waits on the first's answer.
    private static var asking = 0
    private static var notNowCount = 0

    /// Asks for it: AVM's alert, titled `title`, says `why` and what to do,
    /// then `then`; Open Input Monitoring goes on to macOS. Waits, up to
    /// `limit`, for it to be turned on, checking every 2 seconds while
    /// `keepWaiting` is true.
    static func ask(title: String, why: String, then: String, limit: TimeInterval = 300,
                    while keepWaiting: () -> Bool) async -> Outcome {
        if isAllowed { return .allowed }
        if asking > 0 { return await wait(limit, keepWaiting, notNows: notNowCount) }
        asking += 1
        defer { asking -= 1 }
        let listed = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeUnknown
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = why + " "
            + (listed ? steps : "macOS asks next: choose Open System Settings, then turn on AVM.")
            + " If macOS then offers to quit and reopen AVM, choose Later. " + then
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Input Monitoring")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        let open = alert.runModal() == .alertFirstButtonReturn
        guard open else {
            notNowCount += 1
            AVMLog.write("Input Monitoring: Not Now", category: "InputMonitoring")
            return .notNow
        }
        AVMLog.write("Input Monitoring: asked (AVM \(listed ? "listed already" : "not listed yet"))", category: "InputMonitoring")
        if listed {
            openSettings()
        } else {
            // macOS's dialog, which lists AVM there. Off the main thread, in
            // case it waits for the answer.
            DispatchQueue.global(qos: .userInitiated).async { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        }
        return await wait(limit, keepWaiting, notNows: notNowCount)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func wait(_ limit: TimeInterval, _ keepWaiting: () -> Bool, notNows: Int) async -> Outcome {
        let started = Date()
        while Date().timeIntervalSince(started) < limit, keepWaiting() {
            if isAllowed {
                AVMLog.write("Input Monitoring: allowed", category: "InputMonitoring")
                return .allowed
            }
            if notNowCount != notNows { return .notNow }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return isAllowed ? .allowed : .gaveUp
    }
}
