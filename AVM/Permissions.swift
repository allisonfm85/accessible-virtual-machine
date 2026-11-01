// Permissions.swift
// AVM — Accessible Virtual Machine
//
// The Permissions window (2026-10-30, the user's request): everything macOS
// has to allow for AVM, in one place, each with what it's for, whether it's
// allowed, and one button to allow it. It opens by itself when AVM opens
// and something AVM needs right now isn't allowed, and not otherwise; AVM >
// Permissions… opens it any time.
//
// Before it, each permission was asked for at the moment it was first
// needed, often mid-start: a tester's keyboard for Windows waited behind an
// Input Monitoring question that sat unanswered for two and a half minutes
// at login, holding up the rest of AVM.
//
// "Needed now" depends on the user's setup: Input Monitoring only with a
// keyboard for Windows chosen, VoiceOver control only with VoiceOver on,
// the microphone or camera only when a machine shares it. The USB helper is
// always needed: USB devices, Bluetooth and braille displays go through it.

import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class PermissionsCenter: ObservableObject {
    static let shared = PermissionsCenter()

    enum State: Equatable {
        case allowed
        case notAllowed
        /// Not something AVM can read without asking; said, not counted.
        case unknown
    }

    struct Item: Identifiable {
        let id: String
        let title: String
        let why: String
        let state: State
        /// Needed for what the user has set up; drives the window opening.
        let neededNow: Bool
        let button: String
    }

    @Published private(set) var items: [Item] = []
    private var window: NSWindow?
    private var activeObserver: NSObjectProtocol?

    private init() {}

    // MARK: Reading the permissions

    func refresh() {
        let configurations = VMStore.shared?.configurations ?? []
        let helper = USBHelperClient.shared.refreshStatus()
        let voiceOverOn = NSWorkspace.shared.isVoiceOverEnabled
        items = [
            Item(id: "helper", title: "USB helper",
                 why: "Sends USB devices, Bluetooth devices, braille displays and a keyboard for Windows to a virtual machine. macOS asks you to allow it in Login Items.",
                 state: helper == .enabled ? .allowed : .notAllowed, neededNow: true,
                 button: helper == .requiresApproval ? "Open Login Items" : "Set Up USB Helper"),
            Item(id: "input", title: "Input Monitoring",
                 why: "Lets a second keyboard type only into Windows, while your Mac's keyboard stays with the Mac.",
                 state: InputMonitoring.isAllowed ? .allowed : .notAllowed,
                 neededNow: configurations.contains { $0.windowsKeyboardID != nil },
                 button: "Allow Input Monitoring"),
            Item(id: "voiceover", title: "VoiceOver control",
                 why: "Lets AVM speak in your own VoiceOver voice while you're in other apps. Two switches: in VoiceOver Utility, General, Allow VoiceOver to be controlled with AppleScript; and AVM allowed to control VoiceOver, which macOS asks about.",
                 state: voiceOverControl == .allowed ? .allowed : (voiceOverControl == .unknown ? .unknown : .notAllowed),
                 neededNow: voiceOverOn,
                 button: voiceOverControl == .scriptingOff ? "Open VoiceOver Utility" : "Allow AVM to Control VoiceOver"),
            Item(id: "microphone", title: "Microphone",
                 why: "Lets a virtual machine hear your Mac's microphone, when it's turned on in that machine's Settings.",
                 state: Self.state(AVCaptureDevice.authorizationStatus(for: .audio)),
                 neededNow: configurations.contains { $0.sharesMicrophone },
                 button: "Allow Microphone"),
            Item(id: "camera", title: "Camera",
                 why: "Lets a virtual machine use your Mac's camera, when it's turned on in that machine's Settings.",
                 state: Self.state(AVCaptureDevice.authorizationStatus(for: .video)),
                 neededNow: configurations.contains { $0.sharesCamera },
                 button: "Allow Camera"),
            Item(id: "network", title: "Local Network",
                 why: "On some networks a virtual machine reaches the internet through a device on your local network. macOS asks the first time a machine needs it; choose Allow.",
                 state: .unknown, neededNow: false,
                 button: "Open Local Network Settings"),
        ]
    }

    var missing: [Item] { items.filter { $0.neededNow && $0.state == .notAllowed } }

    private static func state(_ status: AVAuthorizationStatus) -> State {
        status == .authorized ? .allowed : .notAllowed
    }

    nonisolated enum VoiceOverControl: Equatable, Sendable {
        case allowed
        /// AVM not allowed to control VoiceOver (System Settings, Automation).
        case automationNotAllowed
        /// VoiceOver Utility's "Allow VoiceOver to be controlled with
        /// AppleScript" off.
        case scriptingOff
        /// VoiceOver isn't running, or not checked yet.
        case unknown
    }

    /// The last check of VoiceOver control (checkVoiceOver).
    private(set) var voiceOverControl: VoiceOverControl = .unknown

    /// Asks VoiceOver itself (2026-10-30): VoiceOver Utility's switch used
    /// to be read from the com.apple.VoiceOver4/default preferences, which
    /// macOS 27 no longer has (VoiceOver's settings are in a protected group
    /// container now), so it read as off with the switch on. Reading the
    /// last phrase VoiceOver said is harmless and needs both switches.
    /// Blocking: off the main thread.
    nonisolated static func probeVoiceOver() -> VoiceOverControl {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return .unknown }
        let status = automationStatus(ask: false)
        if status == OSStatus(errAEEventNotPermitted) || status == OSStatus(errAEEventWouldRequireUserConsent) {
            return .automationNotAllowed
        }
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        script.arguments = ["-e", "with timeout of 3 seconds",
                            "-e", "tell application \"VoiceOver\" to get content of last phrase",
                            "-e", "end timeout"]
        script.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        script.standardError = errors
        guard (try? script.run()) != nil else { return .unknown }
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        script.waitUntilExit()
        if script.terminationStatus == 0 { return .allowed }
        if said.contains("-1743") { return .automationNotAllowed }
        if said.contains("-10000") || said.contains("-10004") { return .scriptingOff }
        AVMLog.write("AVM: Permissions — VoiceOver check inconclusive: \(said.trimmingCharacters(in: .whitespacesAndNewlines))", category: "Permissions")
        return .unknown
    }

    /// Checks VoiceOver control in the background, then reads everything
    /// again and runs `then`.
    func checkVoiceOver(then: (@MainActor () -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let control = Self.probeVoiceOver()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if control == .allowed { Announcer.shared.voiceOverControlAllowed() }
                    PermissionsCenter.shared.voiceOverControl = control
                    PermissionsCenter.shared.refresh()
                    then?()
                }
            }
        }
    }

    nonisolated static func automationStatus(ask: Bool) -> OSStatus {
        var address = AEAddressDesc()
        let id = "com.apple.VoiceOver"
        let made = id.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, id.utf8.count, &address) }
        guard made == noErr else { return OSStatus(made) }
        defer { AEDisposeDesc(&address) }
        return AEDeterminePermissionToAutomateTarget(&address, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    // MARK: Allowing one

    func allow(_ item: Item) {
        AVMLog.write("AVM: Permissions — \(item.button)", category: "Permissions")
        switch item.id {
        case "helper":
            if USBHelperClient.shared.refreshStatus() == .requiresApproval {
                USBHelperClient.shared.openLoginItems()
            } else {
                _ = USBHelperClient.shared.ensureRegistered()
            }
        case "input":
            Task { _ = await InputMonitoring.ask(title: "Allow Input Monitoring for AVM",
                                                 why: "macOS lets AVM's helper take a keyboard for Windows only when AVM is allowed under Input Monitoring.",
                                                 then: "Come back to AVM's Permissions window afterwards.",
                                                 while: { true }) }
        case "voiceover":
            if voiceOverControl != .scriptingOff {
                // macOS's own question, which waits for the answer; once
                // refused, only System Settings can change it.
                DispatchQueue.global(qos: .userInitiated).async {
                    let answer = Self.automationStatus(ask: true)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if answer == OSStatus(errAEEventNotPermitted),
                               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                NSWorkspace.shared.open(url)
                                Announcer.shared.announce("System Settings is opening Automation. Under AVM, turn on VoiceOver, then come back to AVM's Permissions window.", tone: .info)
                            }
                            PermissionsCenter.shared.checkVoiceOver()
                        }
                    }
                }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/VoiceOver Utility.app"))
                Announcer.shared.announce("VoiceOver Utility is opening. In General, turn on Allow VoiceOver to be controlled with AppleScript, then come back to AVM's Permissions window.", tone: .info)
            }
        case "microphone", "camera":
            AVCaptureDevice.requestAccess(for: item.id == "camera" ? .video : .audio) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { PermissionsCenter.shared.refresh() } }
            }
            if item.state == .notAllowed, AVCaptureDevice.authorizationStatus(for: item.id == "camera" ? .video : .audio) == .denied {
                // Refused before: only System Settings can change it now.
                let pane = item.id == "camera" ? "Privacy_Camera" : "Privacy_Microphone"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
            }
        case "network":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(url) }
        default:
            break
        }
        refresh()
    }

    // MARK: The window

    /// At launch, once AVM is in front (AVMAppDelegate): only when
    /// something needed now isn't allowed.
    func showIfSomethingIsMissing() {
        checkVoiceOver { [weak self] in self?.showMissing() }
    }

    private func showMissing() {
        guard !missing.isEmpty else { return }
        AVMLog.write("AVM: Permissions — not allowed yet: \(missing.map(\.title).joined(separator: ", ")); showing the window", category: "Permissions")
        show()
    }

    func show() {
        checkVoiceOver()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "AVM Permissions"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PermissionsView(close: { [weak self] in self?.window?.close() }))
        panel.center()
        window = panel
        // Fresh each time AVM comes back, from System Settings say.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PermissionsCenter.shared.checkVoiceOver() }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PermissionsView: View {
    @ObservedObject private var center = PermissionsCenter.shared
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("AVM Permissions")
                        .font(.title)
                        .accessibilityAddTraits(.isHeader)
                    Text(center.missing.isEmpty
                         ? "Everything AVM needs for your setup is allowed."
                         : "AVM needs \(center.missing.count == 1 ? "one permission" : "\(center.missing.count) permissions") for what you've set up. Choose each one's button; macOS asks, or opens the place to turn it on. This window opens by itself only while something is missing; AVM, Permissions opens it any time.")
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(center.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Text(status(item))
                                .accessibilityLabel("Status: \(status(item))")
                            Text(item.why)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if item.state != .allowed {
                                Button(item.button) { center.allow(item) }
                                    .accessibilityHint(item.why)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            HStack {
                Button("Check Again") { center.checkVoiceOver() }
                    .accessibilityHint("Reads every permission again, after you've changed one in System Settings")
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 640)
        .onAppear { center.refresh() }
    }

    private func status(_ item: PermissionsCenter.Item) -> String {
        switch item.state {
        case .allowed: return "Allowed."
        case .notAllowed: return item.neededNow ? "Not allowed yet, and needed for your setup." : "Not allowed yet. Needed only if you use it."
        case .unknown: return "macOS asks when it's first needed."
        }
    }
}
