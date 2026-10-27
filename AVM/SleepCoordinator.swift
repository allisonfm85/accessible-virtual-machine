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
    /// True when AVM paused the VM for sleep, so only that pause is undone.
    private var pausedForSleep = false
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
        guard let manager = VMManager.shared, manager.state == .running else {
            IOAllowPowerChange(rootPort, token)
            return
        }
        AVMLog.write("AVM: Sleep — the Mac is going to sleep; pausing the VM.")
        let port = rootPort
        // Sleep goes ahead after the pause, or after holdLimit if QEMU is
        // slow to answer, whichever comes first; never both.
        let once = AllowOnce(port: port, token: token)
        asleep = true
        Task { @MainActor in
            do {
                try await manager.pauseVM()
                guard self.asleep else {
                    AVMLog.write("AVM: Sleep — the pause landed after the Mac woke; resuming at once.")
                    try? await manager.resumeVM()
                    return
                }
                self.pausedForSleep = true
            } catch {
                AVMLog.write("AVM: Sleep — the pause failed (\(error.localizedDescription)); letting the Mac sleep anyway.")
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
        guard pausedForSleep else { return }
        pausedForSleep = false
        guard let manager = VMManager.shared, manager.state == .paused else { return }
        let guest = VMManager.currentGuestName
        Task { @MainActor in
            do {
                try await manager.resumeVM()
                AVMLog.write("AVM: Sleep — the Mac woke; the VM is running again.")
                // The guest agent sets the clock at once (GuestAgent.swift);
                // without it, Windows catches up at its next time sync.
                let clockSet = await manager.setGuestClock()
                Announcer.shared.announce(
                    clockSet
                        ? "\(guest) was paused while the Mac slept, and is running again."
                        : "\(guest) was paused while the Mac slept, and is running again. Its clock may take a while to catch up.",
                    tone: .info
                )
            } catch {
                Announcer.shared.announce("\(guest) was paused while the Mac slept and could not be resumed. Reason: \(error.localizedDescription) Next: choose Resume on the dashboard.", tone: .failure)
            }
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
