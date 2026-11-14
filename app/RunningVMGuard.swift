// RunningVMGuard.swift
// AVM — Accessible Virtual Machine
//
// Makes sure no virtual machine runs where AVM can't see it. Added
// 2026-11-14 for issue #264. Three places, one rule:
//
//   1. QUIT: a running VM is shut down or turned off before AVM quits, or
//      the quit is cancelled. The user decides which.
//   2. LAUNCH: a VM left running from before (AVM crashed, was force
//      quit, or was quit by a version without this guard) is announced,
//      with an offer to shut it down. That includes a VM that has since
//      been deleted.
//   3. DELETE (and Reclaim, in VMStore): a VM whose QEMU is still running
//      is never moved to the Trash.
//
// The processes themselves are found by VMProcessScanner, from their
// arguments, not from AVM's in-memory state, which is what failed in #264.
//
// WHY QUIT DOES NOT USE .terminateLater (tested 2026-11-14, on a small
// AppKit test app, macOS 27.2.1): while a .terminateLater reply is
// pending, AppKit runs the main run loop in modal panel mode only. The main
// dispatch queue is not serviced there, so main-actor Tasks do not run.
// Every step of a shutdown runs on the main actor (stopVM's QMP command,
// the QEMU exit handler that publishes .stopped), so a shutdown started
// from .terminateLater would hang. And a second Quit during the wait quit
// AVM at once, without calling applicationShouldTerminate again.
// So the quit is cancelled, the shutdown runs normally, with the dashboard
// and its Force Stop still working, and AVM quits itself when the VM has
// stopped (NSApp.terminate again, which now finds nothing running). Quit
// pressed again during the wait asks again, with the choices for a VM
// that is shutting down.
//
// The cost: when the Mac is logging out or restarting, cancelling the quit
// cancels the logout. AVM still quits once the VM has shut down, and the
// user logs out again. Waiting for the guest is worth that.
//
// THE LAST SAFETY NET is terminateLeftoverVMProcesses, called from
// applicationWillTerminate on every quit. It stops any QEMU or swtpm that
// is still a child of this AVM, for example one that Force Stop has
// signalled but which hasn't exited yet (forceStopVM's SIGKILL escalation
// runs in a Task that won't get to run once AVM exits).
//
// ALERTS: the default button (Return) is always the choice that loses
// nothing: Shut Down, or Cancel where there is no gentle way. Force Off
// is never the default. Every outcome is announced; the questions
// themselves are alerts, which VoiceOver reads when they open.

import AppKit

@MainActor
final class RunningVMGuard {

    static let shared = RunningVMGuard()

    private init() {}

    // MARK: - Quit

    /// True while AVM is waiting for a VM to shut down so it can quit.
    private var quitWhenStopped = false

    /// Called from applicationShouldTerminate.
    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard let manager = VMManager.shared else {
            AVMLog.write("RunningVMGuard: quit — no VM session; quitting.")
            AVMLog.flush()
            return .terminateNow
        }
        let guest = VMManager.currentGuestName

        switch manager.state {
        case .stopped, .error:
            AVMLog.write("RunningVMGuard: quit — VM is \(manager.state); quitting.")
            AVMLog.flush()
            return .terminateNow

        case .running, .paused:
            unlockKeyboard()
            AVMLog.write("RunningVMGuard: quit requested while the VM is \(manager.state); asking.")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(guest) is still running."
            alert.informativeText = "Shut down \(guest) before AVM quits? Shutting down can take a few minutes, and AVM quits when it's done. Force Off is like holding down a computer's power button: anything unsaved in \(guest) is lost."
            alert.addButton(withTitle: "Shut Down and Quit")
            alert.addButton(withTitle: "Force Off and Quit")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                AVMLog.write("RunningVMGuard: quit — chose Shut Down and Quit.")
                shutDownThenQuit(manager)
                return .terminateCancel
            case .alertSecondButtonReturn:
                return forceOffAndQuit(manager)
            default:
                AVMLog.write("RunningVMGuard: quit — cancelled; \(guest) keeps running.")
                Announcer.shared.announce("AVM will stay open. \(guest) is still running.", tone: .info)
                return .terminateCancel
            }

        case .stopping:
            unlockKeyboard()
            AVMLog.write("RunningVMGuard: quit requested while the VM is shutting down (waiting to quit: \(quitWhenStopped)); asking.")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(guest) is still shutting down."
            alert.informativeText = "AVM can quit when \(guest) has shut down, or turn it off now. Force Off is like holding down a computer's power button: anything unsaved in \(guest) is lost."
            alert.addButton(withTitle: "Wait and Quit")
            alert.addButton(withTitle: "Force Off and Quit")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                AVMLog.write("RunningVMGuard: quit — chose Wait and Quit.")
                shutDownThenQuit(manager)
                return .terminateCancel
            case .alertSecondButtonReturn:
                return forceOffAndQuit(manager)
            default:
                // Cancel means stay open, including when an earlier Wait
                // and Quit is pending: the newest answer wins.
                AVMLog.write("RunningVMGuard: quit — cancelled; AVM stays open while \(guest) shuts down.")
                quitWhenStopped = false
                Announcer.shared.announce("AVM will stay open. \(guest) is still shutting down.", tone: .info)
                return .terminateCancel
            }

        case .starting:
            // Nothing to ask the guest yet: before QMP is up there is no
            // shutdown request to send. Stopping now is safe for an
            // install (the next Start builds or reuses the media again).
            unlockKeyboard()
            AVMLog.write("RunningVMGuard: quit requested while the VM is starting; asking.")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(guest) is starting."
            alert.informativeText = "To quit now, AVM has to stop \(guest) before it finishes starting. If \(guest) is being installed, the install starts over next time."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Stop and Quit")
            if alert.runModal() == .alertSecondButtonReturn {
                return forceOffAndQuit(manager)
            }
            AVMLog.write("RunningVMGuard: quit — cancelled while starting.")
            Announcer.shared.announce("AVM will stay open. \(guest) is still starting.", tone: .info)
            return .terminateCancel
        }
    }

    private func forceOffAndQuit(_ manager: VMManager) -> NSApplication.TerminateReply {
        AVMLog.write("RunningVMGuard: quit — force-stopping the VM, then quitting.")
        AVMLog.flush()
        // forceStopVM signals QEMU and swtpm; applicationWillTerminate's
        // safety net waits for them to exit, which forceStopVM's own
        // SIGKILL escalation would not get to do once AVM is gone.
        manager.forceStopVM()
        return .terminateNow
    }

    /// Asks the guest to shut down (unless it already is) and quits AVM
    /// once it has. Never force-stops on its own, same rule as the Stop
    /// button: a Windows update can make shutdown take many minutes.
    private func shutDownThenQuit(_ manager: VMManager) {
        let guest = VMManager.currentGuestName
        let alreadyWaiting = quitWhenStopped
        quitWhenStopped = true
        Announcer.shared.announce("Shutting down \(guest). AVM will quit when it has shut down.", tone: .info)
        guard !alreadyWaiting else {
            AVMLog.write("RunningVMGuard: quit — already waiting for the shutdown; nothing new to start.")
            return
        }

        Task { @MainActor in
            do {
                if case .paused = manager.state {
                    // The shutdown request only reaches a running guest.
                    AVMLog.write("RunningVMGuard: quit — VM is paused; resuming before shutdown.")
                    try await manager.resumeVM()
                }
                if case .running = manager.state {
                    try await manager.stopVM()
                }
            } catch {
                AVMLog.write("RunningVMGuard: quit — the shutdown request failed: \(error.localizedDescription)")
                quitWhenStopped = false
                Announcer.shared.announce(
                    "\(guest) could not be asked to shut down, so AVM is staying open. Reason: \(error.localizedDescription). Next: quit again and choose Force Off and Quit, or use Force Stop.",
                    tone: .failure
                )
                return
            }

            let reminderAfter: TimeInterval = 120
            let started = Date()
            var reminded = false
            while quitWhenStopped {
                switch manager.state {
                case .stopped, .error:
                    AVMLog.write("RunningVMGuard: quit — VM is \(manager.state) after \(Int(Date().timeIntervalSince(started))) s; quitting.")
                    quitWhenStopped = false
                    NSApp.terminate(nil)
                    return
                case .running:
                    // Back to running without stopping: the shutdown was
                    // refused, or Start was pressed again. Don't quit out
                    // from under it.
                    AVMLog.write("RunningVMGuard: quit — VM is running again; not quitting.")
                    quitWhenStopped = false
                    Announcer.shared.announce("\(guest) is still running, so AVM is staying open.", tone: .failure)
                    return
                default:
                    break
                }
                if !reminded, Date().timeIntervalSince(started) >= reminderAfter {
                    reminded = true
                    AVMLog.write("RunningVMGuard: quit — still shutting down after \(Int(reminderAfter)) s; reminded the user, still waiting.")
                    Announcer.shared.announce(
                        "\(guest) is still shutting down. AVM will quit when it's done. To quit now, quit again and choose Force Off and Quit.",
                        tone: .info
                    )
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            AVMLog.write("RunningVMGuard: quit — no longer waiting to quit (cancelled).")
        }
    }

    /// Returns the keyboard to the Mac before a quit question, so focus
    /// lock's enforcement doesn't pull focus back to the guest's display
    /// while the alert is open (a quit can come from the Dock while the
    /// keyboard is in the guest).
    private func unlockKeyboard() {
        if let focusLock = FocusLockManager.shared, focusLock.isLocked {
            AVMLog.write("RunningVMGuard: unlocking the keyboard before the quit question.")
            focusLock.unlock()
        }
    }

    /// The last safety net, called from applicationWillTerminate on every
    /// quit: stops any QEMU or swtpm this AVM started that is still
    /// running. Synchronous, because nothing asynchronous is sure to run
    /// after this. Logs with NSLog: AVMLog writes are asynchronous and can
    /// be lost at exit (TERMINATION-CONTEXT RULE in AVMAppDelegate).
    nonisolated static func terminateLeftoverVMProcesses() {
        let leftovers = VMProcessScanner.scan().filter(\.isOurs)
        guard !leftovers.isEmpty else {
            NSLog("AVM: RunningVMGuard — no VM processes left at quit.")
            return
        }
        NSLog("AVM: RunningVMGuard — \(leftovers.count) VM process(es) still running at quit; stopping them.")
        let allGone = VMProcessScanner.forceStop(leftovers, log: { NSLog("AVM: %@", $0) })
        NSLog("AVM: RunningVMGuard — leftover VM processes \(allGone ? "stopped" : "NOT all stopped").")
    }

    // MARK: - Launch

    private var checkedAtLaunch = false

    /// Looks for VMs left running from before and offers to shut each one
    /// down. Once per launch. Called from ContentView's first appearance,
    /// which is the first place both the window (for the alerts) and the
    /// VM list (for the names) exist.
    func checkForLeftoverVMsAtLaunch(store: VMStore) {
        guard !checkedAtLaunch else { return }
        checkedAtLaunch = true
        Task { @MainActor in
            // Let the window open and VoiceOver read it before an alert
            // takes focus.
            try? await Task.sleep(for: .seconds(1.5))
            let strays = await Task.detached { VMProcessScanner.strays() }.value
            guard !strays.isEmpty else {
                AVMLog.write("RunningVMGuard: launch — no virtual machines left running from before.")
                return
            }
            AVMLog.write("RunningVMGuard: launch — \(strays.count) virtual machine(s) left running from before.")
            // strays() leaves out VMs a running AVM owns: this one's
            // children (a VM started in the second and a half since
            // launch) and another copy's.
            for (vmID, processes) in strays.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                guard processes.contains(where: { $0.kind == .qemu }) else {
                    // swtpm with no QEMU: nothing is running in it, so there
                    // is nothing to ask about. Stop it quietly (it holds the
                    // TPM state lock, and for a deleted VM, nothing else
                    // ever would).
                    AVMLog.write("RunningVMGuard: launch — swtpm with no QEMU for \(vmID.uuidString); stopping it.")
                    _ = await Task.detached { VMProcessScanner.forceStop(processes) }.value
                    continue
                }
                let name = store.configurations.first(where: { $0.id == vmID })?.name
                await offerToStop(vmID: vmID, name: name, processes: processes, context: .launch)
            }
        }
    }

    // MARK: - Delete

    /// Delete found this VM's QEMU running outside the current session.
    /// Explains, and offers to stop it; the user presses Delete again
    /// afterward. Deleting in the same step would chain an irreversible
    /// action onto a force-off, two decisions in one press.
    func offerToStopBeforeDelete(_ configuration: VMConfiguration) {
        let processes = VMProcessScanner.processes(for: configuration.id)
        // Another copy of AVM (a Debug build next to the release, say) is
        // running it. That copy shows it and can stop it; stopping it from
        // here would leave that copy saying it stopped unexpectedly.
        if processes.contains(where: { $0.kind == .qemu && $0.parentIsAnotherAVM }) {
            AVMLog.write("RunningVMGuard: delete — '\(configuration.name)' is running in another copy of AVM; refusing.")
            Announcer.shared.announce(
                "Cannot delete \(configuration.name). It is running in another copy of AVM. Stop it there first.",
                tone: .failure
            )
            return
        }
        Task { @MainActor in
            await offerToStop(vmID: configuration.id, name: configuration.name, processes: processes, context: .delete)
        }
    }

    // MARK: - Stopping a leftover VM

    private enum Context {
        case launch
        case delete
    }

    private func offerToStop(vmID: UUID, name: String?, processes: [VMProcess], context: Context) async {
        let qemu = processes.first(where: { $0.kind == .qemu })
        let memory = qemu?.memoryMB.map(VMProcessScanner.spokenMemory)
        // Spoken name: the VM's, or "The deleted virtual machine" for one
        // that is no longer in the list.
        let label = name ?? "The deleted virtual machine"
        let memoryClause = memory.map { ", and it's using \($0) of memory" } ?? ""
        let forceOffNote = "Force Off is like holding down a computer's power button: anything unsaved in it is lost."

        AVMLog.write("RunningVMGuard: \(context) — \(name.map { "'\($0)'" } ?? "deleted VM") (\(vmID.uuidString)) is running outside AVM: \(processes.map { "\($0.kind.rawValue) pid \($0.pid)" }.joined(separator: ", ")).")

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch context {
        case .launch:
            if let name {
                alert.messageText = "\(name) is still running."
                alert.informativeText = "It kept running after AVM last closed\(memoryClause). AVM can't show it or connect to it. Shut it down? \(forceOffNote)"
            } else {
                alert.messageText = "A virtual machine that was deleted is still running."
                alert.informativeText = "It kept running after it was deleted\(memoryClause). AVM can't show it or connect to it, and its files may be in the Trash. Shut it down? \(forceOffNote)"
            }
            alert.addButton(withTitle: "Shut Down")
            alert.addButton(withTitle: "Force Off")
            let leave = alert.addButton(withTitle: "Leave Running")
            leave.keyEquivalent = "\u{1b}"   // Escape
        case .delete:
            alert.messageText = "\(label) is still running."
            alert.informativeText = "It's running in the background, where AVM can't show it, and it has to stop before it can be deleted. Shut it down? \(forceOffNote)"
            alert.addButton(withTitle: "Shut Down")
            alert.addButton(withTitle: "Force Off")
            alert.addButton(withTitle: "Cancel")
        }

        let response = alert.runModal()

        // The question can sit open for a while. If the VM stopped in the
        // meantime, say so rather than act on it.
        if response != .alertThirdButtonReturn,
           let qemu, !(await Task.detached { VMProcessScanner.isStillRunning(qemu) }.value) {
            AVMLog.write("RunningVMGuard: \(context) — \(vmID.uuidString) stopped while the question was open.")
            Announcer.shared.announce(
                context == .delete ? "\(label) has already stopped. You can delete it now." : "\(label) has already stopped.",
                tone: .info
            )
            _ = await Task.detached { VMProcessScanner.forceStop(processes) }.value   // its swtpm, if left
            return
        }

        switch response {
        case .alertFirstButtonReturn:
            AVMLog.write("RunningVMGuard: \(context) — chose Shut Down for \(vmID.uuidString).")
            await shutDownLeftover(vmID: vmID, label: label, processes: processes, context: context)
        case .alertSecondButtonReturn:
            AVMLog.write("RunningVMGuard: \(context) — chose Force Off for \(vmID.uuidString).")
            await forceOffLeftover(label: label, processes: processes, context: context)
        default:
            AVMLog.write("RunningVMGuard: \(context) — left \(vmID.uuidString) running.")
            switch context {
            case .launch:
                Announcer.shared.announce("\(label) is still running.", tone: .info)
            case .delete:
                Announcer.shared.announce("\(label) was not deleted. It is still running.", tone: .info)
            }
        }
    }

    private func shutDownLeftover(vmID: UUID, label: String, processes: [VMProcess], context: Context) async {
        guard let qemu = processes.first(where: { $0.kind == .qemu }) else { return }
        Announcer.shared.announce("Shutting down \(label).", tone: .info)
        let delivered = await Task.detached { VMProcessScanner.requestShutdown(of: qemu) }.value
        guard delivered else {
            // The alert says it; VoiceOver reads it when it opens.
            await askToForceOff(label: label, processes: processes, context: context,
                                why: "\(label) didn't answer the request to shut down.")
            return
        }

        // Same patience as the Stop button: two minutes, then ask. Never
        // forced without asking.
        while true {
            let exited = await Task.detached { VMProcessScanner.waitForExit(qemu, timeout: 120) }.value
            if exited {
                // swtpm normally exits with QEMU; make sure.
                let swtpm = processes.filter { $0.kind == .swtpm }
                _ = await Task.detached { VMProcessScanner.forceStop(swtpm) }.value
                AVMLog.write("RunningVMGuard: \(context) — \(vmID.uuidString) has shut down.")
                Announcer.shared.announce(shutDownMessage(label: label, context: context), tone: .success)
                return
            }
            AVMLog.write("RunningVMGuard: \(context) — \(vmID.uuidString) still shutting down after two minutes; asking.")
            let keepWaiting = await askToForceOff(
                label: label, processes: processes, context: context,
                why: "\(label) is still shutting down after two minutes.",
                offerToKeepWaiting: true
            )
            if !keepWaiting { return }
        }
    }

    /// Asks whether to force off a leftover VM that didn't shut down.
    /// Returns true only if the user chose to keep waiting.
    @discardableResult
    private func askToForceOff(label: String, processes: [VMProcess], context: Context, why: String, offerToKeepWaiting: Bool = false) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = why
        alert.informativeText = "Force Off is like holding down a computer's power button: anything unsaved in it is lost."
        if offerToKeepWaiting {
            alert.addButton(withTitle: "Keep Waiting")
        }
        alert.addButton(withTitle: "Force Off")
        let leave = alert.addButton(withTitle: context == .delete ? "Cancel" : "Leave Running")
        leave.keyEquivalent = "\u{1b}"   // Escape

        let response = alert.runModal()
        let forceOffResponse: NSApplication.ModalResponse = offerToKeepWaiting ? .alertSecondButtonReturn : .alertFirstButtonReturn
        if offerToKeepWaiting, response == .alertFirstButtonReturn {
            AVMLog.write("RunningVMGuard: \(context) — chose Keep Waiting.")
            Announcer.shared.announce("Still waiting for \(label) to shut down.", tone: .info)
            return true
        }
        if response == forceOffResponse {
            AVMLog.write("RunningVMGuard: \(context) — chose Force Off after the shutdown didn't finish.")
            await forceOffLeftover(label: label, processes: processes, context: context)
            return false
        }
        AVMLog.write("RunningVMGuard: \(context) — left it running after the shutdown didn't finish.")
        Announcer.shared.announce(
            context == .delete ? "\(label) was not deleted. It is still running." : "\(label) is still running.",
            tone: .info
        )
        return false
    }

    private func forceOffLeftover(label: String, processes: [VMProcess], context: Context) async {
        let allGone = await Task.detached { VMProcessScanner.forceStop(processes) }.value
        if allGone {
            Announcer.shared.announce(
                context == .delete ? "\(label) is turned off. You can delete it now." : "\(label) is turned off.",
                tone: .success
            )
        } else {
            Announcer.shared.announce(
                "\(label) could not be turned off. Next: restart the Mac, then open AVM again.",
                tone: .failure
            )
        }
    }

    private func shutDownMessage(label: String, context: Context) -> String {
        context == .delete ? "\(label) has shut down. You can delete it now." : "\(label) has shut down."
    }
}
