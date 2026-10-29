// MachineSessions.swift
// AVM — Accessible Virtual Machine
//
// SEVERAL MACHINES AT ONCE (2026-10-27). Every running Windows or Linux
// machine has a VMSession here, keyed by its configuration's id, and its
// own window (MachineWindow) titled with its name, as Hyper-V's and
// VMware's do. The main window is always the list of machines; each row
// has its own controls.
//
// "Current" is the machine whose window was last in front (or the one
// just started): the Virtual Machine menu, Speak Status's keyboard line
// and the rest of AVM that acts on "the" machine act on it, through
// VMManager.shared and VMSession.current, which follow it here.
//
// Entering a machine brings its window forward and gives it the keyboard;
// Control-Command-Escape gives the keyboard back and brings the main
// window forward, as the main window's dashboard used to come back. A
// machine's window closes when the machine stops; closing it asks first.

import AppKit
import SwiftUI
import Combine

@MainActor
final class MachineSessions: ObservableObject {

    static let shared = MachineSessions()

    @Published private(set) var sessions: [UUID: VMSession] = [:]
    @Published private(set) var currentID: UUID?
    /// The last start failure or stop with an error, for the main window.
    @Published var lastError: String?

    private var windows: [UUID: MachineWindow] = [:]
    /// For a window made later: a machine started without one gets one
    /// when it's entered.
    private weak var vmStore: VMStore?
    private weak var focusLock: FocusLockManager?
    private var watchers: [UUID: AnyCancellable] = [:]
    /// Machines that have left "stopped" since their Start: a session's
    /// state starts as stopped, which mustn't end it.
    private var begun: Set<UUID> = []

    private init() {}

    var current: VMSession? { currentID.flatMap { sessions[$0] } }

    func session(for id: UUID) -> VMSession? { sessions[id] }

    /// True while any machine is starting, running, paused or stopping.
    var anyActive: Bool {
        sessions.values.contains {
            switch $0.vmState {
            case .stopped, .error: return false
            default: return true
            }
        }
    }

    /// Starts a machine in its own session and window. Spoken on failure.
    /// With no store and focus lock (the test job), or `windowless` (its
    /// setting, or avmctl start --no-window), there's no window until it's
    /// entered.
    @discardableResult
    func start(_ config: VMConfiguration, vmStore: VMStore?, focusLock: FocusLockManager?, windowless: Bool = false, takesKeyboard: Bool = true) -> VMSession {
        if let vmStore { self.vmStore = vmStore }
        if let focusLock { self.focusLock = focusLock }
        if sessions[config.id] != nil {
            Announcer.shared.announce("\(config.name) is already running.", tone: .info)
            enter(config.id)
            return sessions[config.id]!
        }
        lastError = nil
        let session = VMSession(configuration: config)
        session.entersOnFirstShow = takesKeyboard
        sessions[config.id] = session
        if let vmStore, let focusLock, !windowless {
            windows[config.id] = MachineWindow(session: session, vmStore: vmStore, focusLock: focusLock)
        } else if windowless {
            Announcer.shared.announce("Starting \(config.name) without a window. Enter it from AVM's list to see it.", tone: .info)
        }
        // Not while the keyboard is in another machine (2026-10-28, code
        // review): made current at once, a machine started from the list
        // while locked in another came to the front and took its window,
        // not its keyboard. It becomes current when entered.
        if FocusLockManager.shared?.isLocked != true || currentID == nil {
            makeCurrent(config.id)
        }
        watchers[config.id] = session.$vmState
            .combineLatest(session.$restartingAfterInstall)
            .sink { [weak self] state, restarting in
                MainActor.assumeIsolated { self?.stateChanged(config.id, state: state, restarting: restarting) }
            }
        AVMLog.write("AVM: MachineSessions — starting \(config.name); \(sessions.count) machine(s) now.")
        Task {
            do {
                try await session.start()
            } catch {
                // Not a start cut short by Force Stop or Quit (2026-10-28,
                // code review): that's no error to show.
                if !(error is CancellationError) { lastError = error.localizedDescription }
                // Only its own session (2026-10-28, second review): a start cut
                // short by Force Stop ended here after a new Start had made
                // another session for the same machine, and ended that one.
                if sessions[config.id] === session { end(config.id) }
            }
        }
        return session
    }

    /// Makes `id` the machine "the" Virtual Machine menu and the rest of
    /// AVM act on.
    func makeCurrent(_ id: UUID) {
        guard let session = sessions[id] else { return }
        currentID = id
        VMManager.shared = session.manager
        VMActivity.shared.follow(session.manager.state)
        FocusLockManager.shared?.guestName = session.configuration.name
        // A USB device plugged in is offered to the machine being watched
        // for; it moves to this one only when that machine has stopped, so
        // switching windows never drops a pending question (2026-10-27,
        // code audit: restarting the watcher drops them).
        let watched = USBHotPlugWatcher.shared.vmID
        if session.vmState == .running, watched == nil || watched.flatMap({ sessions[$0] }) == nil {
            USBHotPlugWatcher.shared.start(vmID: id)
        }
        AVMPasteboard.shared.refreshEnabled()
        if let view = windows[id]?.captureView {
            FocusLockManager.shared?.registerCaptureView(view)
        }
    }

    /// Brings the machine's window forward and gives it the keyboard. A
    /// machine running without a window gets one now.
    func enter(_ id: UUID) {
        guard let session = sessions[id], session.vmState == .running || session.vmState == .paused else { return }
        // Current first (2026-10-28, second review): a window made now for a
        // machine running without one otherwise saw the keyboard in another
        // machine and said "Enter it from AVM's list" while being entered.
        if let lock = FocusLockManager.shared, lock.isLocked, currentID != id {
            lock.unlock(bringListForward: false)
        }
        makeCurrent(id)
        if windows[id] == nil, let vmStore = vmStore ?? VMStore.shared, let focusLock = focusLock ?? FocusLockManager.shared {
            let window = MachineWindow(session: session, vmStore: vmStore, focusLock: focusLock)
            windows[id] = window
            window.showFirstTime(entering: true)
        }
        windows[id]?.show()
        if let view = windows[id]?.captureView {
            FocusLockManager.shared?.registerCaptureView(view)
        }
        // Once AVM is active (2026-10-28, code review): from the menu bar
        // item, activate() hasn't landed yet, and lock() refused with
        // "switch to AVM" though AVM was coming forward.
        if NSApp.isActive {
            FocusLockManager.shared?.lock()
        } else {
            var token: NSObjectProtocol?
            var done = false
            token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard !done else { return }
                    done = true
                    if let token { NotificationCenter.default.removeObserver(token) }
                    FocusLockManager.shared?.lock()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    guard !done else { return }
                    done = true
                    if let token { NotificationCenter.default.removeObserver(token) }
                    FocusLockManager.shared?.lock()
                }
            }
        }
    }

    private func stateChanged(_ id: UUID, state: VMRuntimeState, restarting: Bool) {
        if id == currentID { VMActivity.shared.follow(state) }
        switch state {
        case .starting:
            begun.insert(id)
        case .running:
            begun.insert(id)
            windows[id]?.showFirstTime()
        case .stopped, .error:
            guard begun.contains(id), !restarting else { return }
            if case .error(let message) = state { lastError = message }
            end(id)
        default:
            break
        }
    }

    /// Ends a session whose machine has stopped: its window closes, the
    /// keyboard comes back if it was in it, and another running machine
    /// becomes current.
    func end(_ id: UUID) {
        guard sessions[id] != nil else { return }
        if currentID == id, let lock = FocusLockManager.shared, lock.isLocked { lock.unlock() }
        // Gone from the list before its window closes (2026-10-28, code
        // review): closing it makes another machine's window key, whose
        // makeCurrent moves the USB watcher only once this session is gone.
        sessions[id] = nil
        begun.remove(id)
        windows[id]?.closeForGood()
        windows[id] = nil
        watchers[id] = nil
        AVMLog.write("AVM: MachineSessions — a machine ended; \(sessions.count) still running.")
        AVMPasteboard.shared.refreshEnabled()
        BackgroundMode.shared.machineStopped()
        if currentID == id {
            currentID = nil
            if let next = sessions.keys.first {
                makeCurrent(next)
            } else {
                VMManager.shared = nil
                VMActivity.shared.follow(.stopped)
            }
        }
    }

    /// A machine's display was chosen in its Settings while it runs.
    func displayChosen(_ id: UUID) {
        windows[id]?.displayChosen()
    }

    /// Machine windows that are open, for the second display
    /// (BackgroundMode).
    var windowsForDisplay: [NSWindow] {
        windows.values.map(\.nsWindow).filter(\.isVisible)
    }

    /// Every manager, for quitting and sleep.
    var managers: [VMManager] { sessions.values.map(\.manager) }

    /// The keyboard came back to the Mac (Control-Command-Escape): from a
    /// machine's window, the main window comes forward, where the list of
    /// machines is, as the main window's dashboard used to come back.
    func returnedToMac() {
        if windows.values.contains(where: \.isKey) {
            MainWindowCloseGuard.bringMainWindowForward()
        }
    }
}

// MARK: - A machine's window

/// One Windows or Linux machine's screen, in a window of its own titled
/// with its name. It opens when the machine first runs; it becomes the
/// current machine when it comes to the front; closing it asks how.
@MainActor
final class MachineWindow: NSObject, NSWindowDelegate {
    private let session: VMSession
    private let vmStore: VMStore
    private let focusLock: FocusLockManager
    private let window: NSWindow
    private var shownOnce = false
    private var closing = false

    init(session: VMSession, vmStore: VMStore, focusLock: FocusLockManager) {
        self.session = session
        self.vmStore = vmStore
        self.focusLock = focusLock
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: true)
        super.init()
        window.title = session.configuration.name
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AVMMachine-\(session.configuration.id.uuidString)")
        window.delegate = self
        // Its own display plugged in again: the window moves back to it.
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shownOnce, !self.closing else { return }
                MachineDisplays.displaysChanged(self.window, for: self.latestConfiguration)
            }
        }
    }

    deinit {
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
    }

    private nonisolated(unsafe) var screensObserver: NSObjectProtocol?

    /// The machine's settings as saved now: a display chosen while it
    /// runs counts.
    private var latestConfiguration: VMConfiguration {
        vmStore.configurations.first { $0.id == session.configuration.id } ?? session.configuration
    }

    /// Its display was chosen in Settings while it runs: it goes there now.
    func displayChosen() {
        guard shownOnce, !closing, let screen = MachineDisplays.screen(for: latestConfiguration) else { return }
        MachineDisplays.fill(window, on: screen)
    }

    /// The machine's screen view, which takes the keyboard.
    var captureView: NSView? {
        func find(_ view: NSView) -> NSView? {
            if view is SPICEKeyCaptureView { return view }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// The first time the machine runs: its window opens in front, and its
    /// screen is made then, not before: the screen connects to QEMU and
    /// takes the keyboard as it appears (VMView.onAppear). Not while the
    /// keyboard is in another machine (2026-10-27, code audit): the window
    /// waits behind, and Enter brings it forward.
    /// `entering`: Enter is bringing it forward now, so none of the "later"
    /// words below apply (2026-10-28).
    func showFirstTime(entering: Bool = false) {
        guard !shownOnce else { return }
        shownOnce = true
        let root = VMView(session: session)
            .environmentObject(vmStore)
            .environmentObject(focusLock)
        window.contentViewController = NSHostingController(rootView: root)
        if window.frameAutosaveName.isEmpty || !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        // On its own display, or the second one, when chosen
        // (MachineDisplays).
        MachineDisplays.placeOpening(window, for: latestConfiguration)
        let elsewhere = focusLock.isLocked && MachineSessions.shared.currentID != session.configuration.id
        if entering {
            show()
        } else if elsewhere {
            window.orderBack(nil)
            Announcer.shared.announce("\(session.configuration.name) is running. Enter it from AVM's list when you're ready.", tone: .info)
        } else if !session.entersOnFirstShow {
            // Started when AVM opened, with a keyboard of its own
            // (2026-10-28): its window opens, and the Mac's keyboard stays
            // on the Mac.
            window.orderFront(nil)
            Announcer.shared.announce("\(session.configuration.name) is running. Your keyboard stays on the Mac; its own keyboard types into it. Enter \(session.configuration.name) from AVM's list to use this keyboard there too.", tone: .info)
        } else {
            show()
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeForGood() {
        closing = true
        window.orderOut(nil)
        window.close()
    }

    var isKey: Bool { window.isKeyWindow }
    var nsWindow: NSWindow { window }

    func windowDidBecomeKey(_ notification: Notification) {
        // The keyboard was in another machine (2026-10-28, code review): it
        // comes back to the Mac, so the lock never outlives its window.
        if let lock = FocusLockManager.shared, lock.isLocked, MachineSessions.shared.currentID != session.configuration.id {
            // Without bringing the list forward (2026-10-28, second review):
            // this window was just chosen.
            lock.unlock(bringListForward: false)
        }
        MachineSessions.shared.makeCurrent(session.configuration.id)
    }

    /// Closing the window asks what to do with the machine, as closing a
    /// macOS machine's window does (MacGuest.windowShouldClose).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        let name = session.configuration.name
        let alert = NSAlert()
        alert.messageText = "Close \(name)?"
        alert.informativeText = "Shut Down asks \(name) to shut down, as its power button would. Keep Running hides this window; Enter \(name) in AVM's main window brings it back."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Shut Down")
        let saveable = session.canSave
        if saveable {
            alert.addButton(withTitle: "Save")
            alert.informativeText += " Save keeps it as it is, open apps and all, and its next Start carries on from there."
        }
        let choice = alert.runModal()
        switch choice {
        case .alertFirstButtonReturn:
            if let lock = FocusLockManager.shared, lock.isLocked { lock.unlock() }
            window.orderOut(nil)
            MainWindowCloseGuard.bringMainWindowForward()
        case .alertSecondButtonReturn:
            Task { try? await session.stopGracefully() }
        case .alertThirdButtonReturn where saveable:
            Task { await session.saveAndStop() }
        default:
            break
        }
        return false
    }
}
