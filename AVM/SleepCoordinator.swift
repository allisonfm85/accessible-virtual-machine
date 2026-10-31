// SleepCoordinator.swift
// AVM — Accessible Virtual Machine
//
// The Mac going to sleep with a VM running (2026-10-26). Nothing in AVM
// used to notice: the guest kept running into sleep and out of it, which
// can leave USB devices stuck and the guest's clock confused, and a VM
// could keep a Mac with its lid closed busy.
//
// Now, before the Mac sleeps, a running VM is paused, and when the Mac
// wakes it resumes and AVM says so. A VM the user paused stays paused.
// It uses IOKit's system power notifications rather than NSWorkspace's,
// because only IOKit lets AVM hold the sleep until the pause has gone
// through (IOAllowPowerChange), up to a few seconds; an NSWorkspace
// observer returns and the Mac sleeps whether the pause finished or not.

import AppKit
import IOKit.pwr_mgt

@MainActor
final class SleepCoordinator {
    static let shared = SleepCoordinator()

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notifyPort: IONotificationPortRef?
    /// The machines AVM paused for sleep, so only those pauses are undone
    /// (every running machine, 2026-10-27, several at once).
    private var pausedForSleep: [VMManager] = []
    /// Between the Mac's sleep and its wake (2026-10-26, code audit): a
    /// pause that lands after the wake (QEMU slower than holdLimit) is let
    /// go at once, instead of leaving the machine paused with nothing said.
    private var asleep = false
    /// The longest AVM holds the Mac's sleep for the pause.
    private static let holdLimit: Duration = .seconds(5)

    private init() {}

    /// Called once at launch by the app delegate.
    func start() {
        guard rootPort == 0 else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let coordinator = Unmanaged<SleepCoordinator>.fromOpaque(refcon).takeUnretainedValue()
            let token = Int(bitPattern: argument)
            MainActor.assumeIsolated {
                coordinator.handle(messageType, token: token)
            }
        }, &notifier)
        guard rootPort != 0, let notifyPort else {
            AVMLog.write("AVM: Sleep — could not register for power notifications; VMs won't pause for sleep.")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
        AVMLog.write("AVM: Sleep — watching for the Mac going to sleep.")
    }

    // From IOMessage.h, where they are macros Swift can't import:
    // iokit_common_msg(x) is sys_iokit (0xe0000000) | sub_iokit_common (0) | x.
    private static let canSystemSleep: natural_t = 0xe000_0270
    private static let systemWillSleep: natural_t = 0xe000_0280
    private static let systemHasPoweredOn: natural_t = 0xe000_0300

    private func handle(_ message: natural_t, token: Int) {
        switch message {
        case Self.canSystemSleep:
            // Idle sleep asks first; let it happen, and pause when it does.
            IOAllowPowerChange(rootPort, token)
        case Self.systemWillSleep:
            willSleep(token: token)
        case Self.systemHasPoweredOn:
            didWake()
        default:
            break
        }
    }

    private func willSleep(token: Int) {
        let running = MachineSessions.shared.managers.filter { $0.state == .running }
        guard !running.isEmpty else {
            IOAllowPowerChange(rootPort, token)
            return
        }
        AVMLog.write("AVM: Sleep — the Mac is going to sleep; pausing \(running.count) machine(s).")
        let port = rootPort
        // Sleep goes ahead after the pauses, or after holdLimit if QEMU is
        // slow to answer, whichever comes first; never both.
        let once = AllowOnce(port: port, token: token)
        asleep = true
        Task { @MainActor in
            // A moment for the keys first (2026-10-29, sixth audit): the
            // keyboard lock lets go of the guest's held keys as the Mac goes
            // to sleep, through SPICE, and QEMU drops input once paused, so a
            // key held as the lid closed stayed down in Windows after wake.
            try? await Task.sleep(for: .milliseconds(300))
            // All at once (2026-10-28, code review): one slow pause used to
            // run out the hold with the next machine still running.
            await withTaskGroup(of: Void.self) { group in
                for manager in running {
                    group.addTask { @MainActor in
                        do {
                            try await manager.pauseVM()
                            guard self.asleep else {
                                AVMLog.write("AVM: Sleep — a pause landed after the Mac woke; resuming it at once.")
                                try? await manager.resumeVM()
                                return
                            }
                            self.pausedForSleep.append(manager)
                        } catch {
                            AVMLog.write("AVM: Sleep — a pause failed (\(error.localizedDescription)); letting the Mac sleep anyway.")
                        }
                    }
                }
            }
            once.allow()
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.holdLimit)
            once.allow()
        }
    }

    private func didWake() {
        asleep = false
        let paused = pausedForSleep.filter { $0.state == .paused }
        pausedForSleep = []
        guard !paused.isEmpty else { return }
        Task { @MainActor in
            var resumed: [String] = []
            var clocksSet = true
            for manager in paused {
                let name = manager.machineName
                do {
                    try await manager.resumeVM()
                    // The guest agent sets the clock at once (GuestAgent.swift);
                    // without it, Windows catches up at its next time sync.
                    if !(await manager.setGuestClock()) { clocksSet = false }
                    resumed.append(name)
                } catch {
                    Announcer.shared.announce("\(name) was paused while the Mac slept and could not be resumed. Reason: \(error.localizedDescription) Next: choose Resume in its row.", tone: .failure)
                }
            }
            guard !resumed.isEmpty else { return }
            AVMLog.write("AVM: Sleep — the Mac woke; \(resumed.count) machine(s) running again.")
            let names = ListFormatter.localizedString(byJoining: resumed)
            let verb = resumed.count == 1 ? "was" : "were"
            let again = resumed.count == 1 ? "is" : "are"
            Announcer.shared.announce(
                clocksSet
                    ? "\(names) \(verb) paused while the Mac slept, and \(again) running again."
                    : "\(names) \(verb) paused while the Mac slept, and \(again) running again. A clock may take a while to catch up.",
                tone: .info
            )
        }
    }

    /// Calls IOAllowPowerChange once, whichever caller is first.
    @MainActor
    private final class AllowOnce {
        private let port: io_connect_t
        private let token: Int
        private var done = false
        init(port: io_connect_t, token: Int) {
            self.port = port
            self.token = token
        }
        func allow() {
            guard !done else { return }
            done = true
            IOAllowPowerChange(port, token)
        }
    }
}
