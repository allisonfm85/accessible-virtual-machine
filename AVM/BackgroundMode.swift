// BackgroundMode.swift
// AVM — Accessible Virtual Machine
//
// AVM in the background, and AVM at login (2026-10-28, tester idea). With
// a second keyboard that belongs to Windows (WindowsKeyboard.swift), AVM's
// own windows have nothing left to do for a keyboard user: Windows types
// whichever app is in front. So, when the user chooses it:
//
//   - Run in the background: while a machine with a Keyboard for Windows
//     runs, switching away from AVM takes it out of Command-Tab and the
//     Dock, and hides it. AVM's menu bar item, or opening AVM again, brings
//     it back. Off unless chosen; with no such machine running, AVM is an
//     ordinary app.
//   - The second display: with two displays, machine windows open on the
//     one without the menu bar, and in the background they stay there,
//     for a sighted person beside a blind one, instead of hiding.
//   - Open at login, and one machine that starts when AVM opens (its row on
//     the dashboard). Together with the two above, the Mac logs in, AVM
//     opens out of the way, and Windows starts, ready for its keyboard.

import AppKit
import ServiceManagement
import SwiftUI
import Combine

@MainActor
final class BackgroundMode: ObservableObject {
    static let shared = BackgroundMode()

    private static let backgroundKey = "AVMRunInBackground"
    private static let secondDisplayKey = "AVMSecondDisplay"
    private static let autoStartKey = "AVMAutoStartMachine"

    @Published var runInBackground: Bool {
        didSet {
            UserDefaults.standard.set(runInBackground, forKey: Self.backgroundKey)
            if !runInBackground { comeForward(announce: false) }
        }
    }
    @Published var useSecondDisplay: Bool {
        didSet { UserDefaults.standard.set(useSecondDisplay, forKey: Self.secondDisplayKey) }
    }
    /// The machine that starts when AVM opens, if any. One at most.
    @Published var autoStartID: UUID? {
        didSet { UserDefaults.standard.set(autoStartID?.uuidString, forKey: Self.autoStartKey) }
    }
    /// True while AVM is out of Command-Tab and the Dock.
    @Published private(set) var inBackground = false
    /// Open at login, as macOS has it (it can be turned off in System
    /// Settings, so it is read from there, not stored here).
    @Published private(set) var opensAtLogin = false
    @Published private(set) var loginNeedsApproval = false

    private var observers: [NSObjectProtocol] = []
    private var explained = false
    private var autoStarted = false

    private init() {
        let defaults = UserDefaults.standard
        runInBackground = defaults.bool(forKey: Self.backgroundKey)
        useSecondDisplay = defaults.bool(forKey: Self.secondDisplayKey)
        autoStartID = defaults.string(forKey: Self.autoStartKey).flatMap(UUID.init(uuidString:))
        refreshLoginStatus()
    }

    /// At launch (AVMAppDelegate).
    func start() {
        AVMLog.write("AVM: Background and Startup — open at login: \(Self.loginStatusName(SMAppService.mainApp.status)); run in the background: \(runInBackground ? "on" : "off"); second monitor: \(useSecondDisplay ? "on" : "off"); starts when AVM opens: \(autoStartID?.uuidString ?? "none")")
        // The machine that starts when AVM opens, from launch (2026-10-28,
        // a user's log): AVM can open with no main window (macOS restores
        // the windows it had, and that can be none), and the dashboard's
        // own call (ContentView.onAppear) then never came; his machine
        // started two and a half minutes later, when he opened the window.
        // Whichever comes first does it; autoStarted keeps it to once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { BackgroundMode.shared.autoStartFromLaunch() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BackgroundMode.shared.goToBackgroundIfChosen() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BackgroundMode.shared.refreshLoginStatus() }
        })
    }

    // MARK: The background

    /// A running machine has a Keyboard for Windows, so Windows still
    /// types with AVM out of the way.
    var aMachineHasItsKeyboard: Bool {
        MachineSessions.shared.sessions.values.contains {
            $0.vmState == .running && $0.configuration.windowsKeyboardID != nil
        }
    }

    private var applies: Bool { runInBackground && aMachineHasItsKeyboard }

    func goToBackgroundIfChosen() {
        guard applies, !inBackground else { return }
        // Not with a dialog or sheet up: it would be hidden mid-question.
        if NSApp.modalWindow != nil || NSApp.windows.contains(where: { $0.attachedSheet != nil }) { return }
        inBackground = true
        NSApp.setActivationPolicy(.accessory)
        // A machine window on a display without the menu bar stays up
        // there, for someone to watch; the rest goes.
        let menuBarScreen = NSScreen.screens.first
        let watched = MachineSessions.shared.windowsForDisplay.filter { window in
            guard let screen = window.screen else { return false }
            return screen != menuBarScreen
        }
        if watched.isEmpty {
            NSApp.hide(nil)
        } else {
            let keep = Set(watched.map(ObjectIdentifier.init))
            for window in NSApp.windows where window.isVisible && !keep.contains(ObjectIdentifier(window)) {
                if window.level == .normal { window.orderOut(nil) }
            }
            for window in watched { window.orderFrontRegardless() }
        }
        AVMLog.write("AVM: in the background (\(watched.count) machine window(s) left up on another display)")
        if !explained {
            explained = true
            Announcer.shared.announce("AVM is in the background. Your keyboard for Windows still types into it. To bring AVM back, use AVM's item in the menu bar, or open AVM again.", tone: .info)
        }
    }

    /// Back in Command-Tab and the Dock, in front: from the menu bar item,
    /// opening AVM again, or turning the setting off.
    func comeForward(announce: Bool = true, openingDashboard: Bool = true) {
        let wasBackground = inBackground
        inBackground = false
        NSApp.setActivationPolicy(.regular)
        guard wasBackground || announce else { return }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !openingDashboard {
            // A question is coming (2026-10-28, fifth audit): in front is
            // enough; a dashboard opened under it stayed after Cancel.
        } else if MainWindowCloseGuard.hasMainWindow {
            MainWindowCloseGuard.bringMainWindowForward()
        } else if let open = MainWindowCloseGuard.openMainWindow {
            open()
        } else {
            // No main window to bring (2026-10-28, code review: launched
            // with none, Show AVM showed nothing): opening AVM again makes
            // one, as the Dock does.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        if wasBackground { AVMLog.write("AVM: out of the background") }
    }

    /// Whether comeForward can show a dashboard (2026-10-28, fifth audit):
    /// one exists, SwiftUI's opener is known, or no window is visible, so
    /// opening AVM again makes one.
    var canOpenDashboard: Bool {
        MainWindowCloseGuard.hasMainWindow || MainWindowCloseGuard.openMainWindow != nil
            || !NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) }
    }

    /// A machine stopped: with no machine left to type into, AVM is an
    /// ordinary app again, in Command-Tab, though still hidden.
    func machineStopped() {
        guard inBackground, !aMachineHasItsKeyboard else { return }
        inBackground = false
        NSApp.setActivationPolicy(.regular)
        AVMLog.write("AVM: no machine with a keyboard for Windows; back in Command-Tab")
    }

    // MARK: The second display

    /// The display without the menu bar, when there is one.
    static var secondDisplay: NSScreen? {
        let screens = NSScreen.screens
        return screens.count > 1 ? screens.first(where: { $0 != screens[0] }) : nil
    }

    // MARK: Open at login

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        opensAtLogin = status == .enabled
        loginNeedsApproval = status == .requiresApproval
    }

    static func loginStatusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "on"
        case .requiresApproval: return "waiting for approval in Login Items"
        case .notRegistered: return "off"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            AVMLog.write("AVM: open at login \(on ? "on" : "off") failed: \(error.localizedDescription)")
            Announcer.shared.announce("AVM couldn't change Open at Login. Reason: \(error.localizedDescription)", tone: .failure)
        }
        refreshLoginStatus()
        AVMLog.write("AVM: open at login \(on ? "on" : "off") asked; macOS says \(Self.loginStatusName(SMAppService.mainApp.status))")
        // Only the approval is spoken: VoiceOver says the checkbox, and an
        // announcement over it hid the state (2026-10-28, see setAutoStart).
        if on && loginNeedsApproval {
            Announcer.shared.announce("macOS needs your OK. In Login Items in System Settings, turn on AVM.", tone: .info)
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: The machine that starts when AVM opens

    /// Nothing spoken (2026-10-28, two users' logs): AVM's announcement
    /// talked over VoiceOver's own "checked", and both users, not hearing
    /// it, pressed again and turned it off. VoiceOver says the checkbox.
    func setAutoStart(_ config: VMConfiguration, _ on: Bool) {
        if on {
            autoStartID = config.id
            AVMLog.write("AVM: \(config.name) will start when AVM opens")
        } else if autoStartID == config.id {
            autoStartID = nil
            AVMLog.write("AVM: \(config.name) won't start when AVM opens")
        }
    }

    /// From launch, with no dashboard needed (see start()).
    func autoStartFromLaunch() {
        guard !autoStarted, let store = VMStore.shared else { return }
        AVMLog.write("AVM: the dashboard hasn't appeared; starting the chosen machine from launch")
        autoStartIfChosen(in: store.configurations) { config, takesKeyboard in
            if MachineArchiveController.shared.refusesWhileBusy(config) { return }
            if config.guestOS == .macOS {
                MacGuestRunner.shared.start(config)
            } else {
                MachineSessions.shared.start(config, vmStore: store, focusLock: FocusLockManager.shared,
                                             windowless: config.startsWithoutWindow, takesKeyboard: takesKeyboard)
            }
        }
    }

    /// Once, when the main window first appears. `start` is the dashboard's
    /// own Start, and its second argument whether the machine takes the
    /// Mac's keyboard: not when it has a keyboard for Windows of its own
    /// (2026-10-28, a user's report: at login, a blind user's keyboard went
    /// into Windows before they'd done anything). In the background when
    /// chosen, once the machine runs.
    func autoStartIfChosen(in configurations: [VMConfiguration], start: (VMConfiguration, Bool) -> Void) {
        guard !autoStarted else { return }
        autoStarted = true
        guard let id = autoStartID else {
            AVMLog.write("AVM: no machine is chosen to start when AVM opens")
            return
        }
        // Not for the accessibility audit or a test job, which open AVM
        // with options and sample machines of their own.
        if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { return }
        guard let config = configurations.first(where: { $0.id == id }) else {
            AVMLog.write("AVM: the machine chosen to start when AVM opens isn't in the list")
            return
        }
        guard !config.isATemplate, MachineSessions.shared.session(for: id) == nil else { return }
        AVMLog.write("AVM: starting \(config.name), chosen to start when AVM opens (keyboard for Windows: \(config.windowsKeyboardName ?? "none"); AVM active: \(NSApp.isActive), hidden: \(NSApp.isHidden), \(NSApp.activationPolicy() == .regular ? "in Command-Tab" : "not in Command-Tab"))")
        Announcer.shared.announce("Starting \(config.name).", tone: .info)
        // In front when it takes the Mac's keyboard: MachineSessions.start
        // does that now for every start (2026-10-30). A machine with a
        // keyboard for Windows of its own leaves the Mac's keyboard, and
        // the front, alone.
        start(config, config.windowsKeyboardID == nil)
        guard runInBackground, config.windowsKeyboardID != nil else { return }
        Task { @MainActor in
            // Up to ten minutes for a first boot or an update.
            for _ in 0..<600 {
                try? await Task.sleep(for: .seconds(1))
                guard let session = MachineSessions.shared.session(for: id) else { return }
                if session.vmState == .running {
                    try? await Task.sleep(for: .seconds(2))
                    // Unless the user is using AVM now.
                    if !NSApp.isActive || NSApp.keyWindow == nil || MachineSessions.shared.windowsForDisplay.contains(where: \.isKeyWindow) {
                        self.goToBackgroundIfChosen()
                        // Not under a dialog (2026-10-28, fifth audit): the
                        // only time this ran was with one up, since
                        // goToBackgroundIfChosen stands down for it, and AVM
                        // deactivated itself under the question being answered.
                        if !self.inBackground, self.applies, NSApp.modalWindow == nil,
                           !NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
                            // AVM was in front: it goes once the user leaves.
                            NSApp.deactivate()
                        }
                    }
                    return
                }
            }
        }
    }
}

// MARK: - The menu bar item

/// AVM's item in the menu bar while Run in the Background is on: the way
/// back to AVM when it isn't in Command-Tab or the Dock.
struct BackgroundMenu: View {
    @ObservedObject private var background = BackgroundMode.shared
    @ObservedObject private var machines = MachineSessions.shared

    var body: some View {
        Button("Show AVM") { background.comeForward() }
        let running = machines.sessions.values
            .filter { $0.vmState == .running || $0.vmState == .paused }
            .sorted { $0.configuration.name.localizedStandardCompare($1.configuration.name) == .orderedAscending }
        if !running.isEmpty {
            Divider()
            ForEach(running, id: \.configuration.id) { session in
                Button("Enter \(session.configuration.name)") {
                    background.comeForward(announce: false)
                    MachineSessions.shared.enter(session.configuration.id)
                }
            }
        }
        Divider()
        Button("Quit AVM") {
            background.comeForward(announce: false)
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Background and Startup settings

struct BackgroundSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var background = BackgroundMode.shared
    @EnvironmentObject var vmStore: VMStore

    private var autoStartName: String? {
        background.autoStartID.flatMap { id in vmStore.configurations.first { $0.id == id }?.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Background and Startup")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)

            Toggle("Open AVM when you log in", isOn: Binding(
                get: { background.opensAtLogin },
                set: { background.setOpensAtLogin($0) }))
            if background.loginNeedsApproval {
                Text("Waiting for your OK: in System Settings, General, Login Items, turn on AVM.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Run in the background with a keyboard for Windows", isOn: $background.runInBackground)
                .accessibilityHint("While a machine with a keyboard for Windows runs, AVM leaves Command Tab and the Dock when you switch away")
            Text("While a machine with a keyboard for Windows is running, switching away from AVM takes it out of Command-Tab and the Dock. Your keyboard for Windows still types into Windows, and your Mac's keyboard stays with your Mac. To bring AVM back, use its item in the menu bar, or open AVM again. Choose the keyboard in the machine's Settings.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Show machines on the second monitor", isOn: $background.useSecondDisplay)
                .accessibilityHint("With two monitors, a machine's window opens on the one without the menu bar and stays there in the background, unless the machine has its own monitor chosen")
            Text(BackgroundMode.secondDisplay == nil
                 ? "Only one monitor is connected now. With a second one, a machine's window opens there, and stays there while AVM is in the background, for someone to watch. To choose a monitor for one machine, use Monitor in its Settings."
                 : "A machine's window opens on the second monitor, and stays there while AVM is in the background, for someone to watch. To choose a monitor for one machine, use Monitor in its Settings.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text(autoStartName.map { "\($0) starts when AVM opens. To change it, use Start When AVM Opens in a machine's row." }
                 ?? "No machine starts when AVM opens. To choose one, use Start When AVM Opens in its row, while it's shut down.")
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { background.refreshLoginStatus() }
    }
}
