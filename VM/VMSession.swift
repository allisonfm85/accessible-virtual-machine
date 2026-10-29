// VMSession.swift
// AVM — Accessible Virtual Machine

import Foundation
import Combine

/// Represents a single active or recently-ended VM session.
/// Owns the VMManager instance and bridges it to the rest of the UI.
@MainActor
final class VMSession: ObservableObject {

    // MARK: - Published State

    @Published private(set) var vmState: VMRuntimeState = .stopped
    @Published private(set) var consoleOutput: String = ""
    @Published private(set) var qemuVersion: String = ""
    /// Mirror of manager.restartingAfterInstall, so SessionGate can react
    /// when AVM's restart after an Ubuntu install ends (see VMManager).
    @Published private(set) var restartingAfterInstall = false

    // MARK: - Dependencies

    let manager: VMManager
    let configuration: VMConfiguration
    /// false: the machine's window opens without taking the Mac's
    /// keyboard (2026-10-28): a machine started when AVM opens that has a
    /// keyboard for Windows of its own.
    var entersOnFirstShow = true
    /// Its screen is being rebuilt for a QEMU started again (2026-10-28,
    /// fifth audit): the old and new screens leave the lock alone.
    var rebuildingScreen = false
    /// A save is under way (fifth audit): Shut Down waits for it.
    var isSaving: Bool { manager.isSaving }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    /// Set by forceStop, so a graceful stop that is still waiting does not
    /// announce a clean shutdown that never happened.
    private var forceStopRequested = false

    // MARK: - Init

    /// The session for the VM that is running now, for code outside the
    /// view tree: quitting AVM shuts it down through here (2026-10-25).
    /// Weak, like VMManager.shared: ContentView owns the session.
    /// The machine in front (MachineSessions), several being able to run
    /// at once since 2026-10-27.
    static var current: VMSession? { MachineSessions.shared.current }

    init(configuration: VMConfiguration) {
        self.configuration = configuration
        self.manager = VMManager()
        bindManager()
    }

    // MARK: - Binding

    private func bindManager() {
        // VMManager is @MainActor and so is VMSession, so updates already arrive
        // on the main actor. Do NOT add a `.receive(on:)` hop — that asynchronous
        // hop can deliver a state change AFTER a view has already rendered (or
        // drop it relative to the view's update cycle), which previously left the
        // UI showing "stopped" while the VM was actually running. We instead
        // forward each change synchronously inside the same main-actor turn, and
        // also fire objectWillChange so any view observing this session re-renders.
        manager.$state
            .sink { [weak self] newState in
                guard let self else { return }
                self.objectWillChange.send()
                self.vmState = newState
            }
            .store(in: &cancellables)

        manager.$consoleOutput
            .sink { [weak self] newOutput in
                guard let self else { return }
                self.consoleOutput = newOutput
            }
            .store(in: &cancellables)

        manager.$restartingAfterInstall
            .sink { [weak self] value in
                guard let self else { return }
                self.restartingAfterInstall = value
            }
            .store(in: &cancellables)

        manager.$qemuVersion
            .sink { [weak self] newVersion in
                guard let self else { return }
                self.qemuVersion = newVersion
            }
            .store(in: &cancellables)

        // A save starting or ending redraws the row (2026-10-29, sixth
        // audit): isSaving is read from the manager, and Shut Down, Save
        // and Pause stayed offered for the whole save.
        manager.$savingTask
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // And a restore point (2026-10-29, seventh audit).
        manager.$takingRestorePoint
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Session Control

    func start() async throws {
        try await manager.startVM(configuration: configuration)
    }

    func stop() async throws {
        try await manager.stopVM()
    }

    /// The main window's Stop. Asks Windows to shut down and waits until it
    /// has, so the session, and the VMManager inside it, stay alive through
    /// the whole shutdown.
    ///
    /// Why (2026-09-27): the main window used to throw the session away
    /// right after the request. VMManager's deinit then killed QEMU in the
    /// middle of Windows' shutdown, like pulling the plug, with nothing in
    /// the log, no Stopped state, and the USB watcher left running.
    ///
    /// Never force-stops on its own: a Windows update can make shutdown take
    /// many minutes. After two minutes it reminds the user once, then keeps
    /// waiting. A paused VM is resumed first, because the shutdown request
    /// only reaches a running guest. Wording approved by Allison 2026-09-27.
    /// Quit Now (2026-10-29, seventh audit): the shutdown wait, if one is
    /// running, must not read the end as a clean shut down.
    func terminateForQuit() {
        forceStopRequested = true
        manager.terminateForQuit()
    }

    func stopGracefully() async throws {
        forceStopRequested = false
        // Once (2026-10-29, seventh audit): a second Shut Down started a
        // second wait, and "has shut down" was said twice.
        if case .stopping = manager.state {
            throw AVMError.refused("\(configuration.name) is already shutting down.")
        }
        // A restore point under way finishes first (seventh audit).
        if manager.takingRestorePoint {
            Announcer.shared.announce("\(configuration.name) is taking a restore point, and shuts down when that's done.", tone: .info)
            while manager.takingRestorePoint { try? await Task.sleep(for: .milliseconds(200)) }
        }
        // A save under way finishes first (2026-10-29, sixth audit): a paused
        // machine was resumed in the middle of its own save, "Shutting down"
        // was said, and then the shut down was refused. The save stops it.
        if let saving = manager.savingTask {
            AVMLog.write("VMSession: stopGracefully: a save is under way; waiting for it")
            Announcer.shared.announce("\(configuration.name) is being saved, and stops when that's done.", tone: .info)
            _ = await saving.value
            switch manager.state {
            case .running, .paused: break   // the save failed: shut down as asked
            default: return
            }
        }
        if case .paused = manager.state {
            AVMLog.write("VMSession: stopGracefully: VM is paused; resuming before shutdown")
            try await manager.resumeVM()
        }
        Announcer.shared.announce("Shutting down \(configuration.name).", tone: .info)
        AVMLog.write("VMSession: stopGracefully: shutdown requested; waiting for the VM to stop")
        try await manager.stopVM()

        switch manager.state {
        case .stopping, .stopped, .error:
            break
        default:
            AVMLog.write("VMSession: stopGracefully: VM was not in a state that can shut down (\(manager.state)); not waiting")
            throw StopError.notRunning
        }

        let reminderAfter: TimeInterval = 120
        // The guest's agent is asked after a minute (2026-10-28, a tester:
        // Windows sometimes hangs at Shut Down): the power button is an
        // ACPI event Windows can ignore at its lock screen or behind a
        // "save your work?" question; the agent's request closes apps.
        let agentAfter: TimeInterval = 60
        let started = Date()
        var reminded = false
        var askedAgent = false
        var warnedAboutAgent = false
        // When the agent is asked: 15 seconds after the warning that says
        // so, however long the warning's own question took (sixth audit).
        var agentAt = agentAfter
        while true {
            switch manager.state {
            case .stopped:
                if forceStopRequested {
                    AVMLog.write("VMSession: stopGracefully: VM was force-stopped during shutdown")
                } else {
                    AVMLog.write("VMSession: stopGracefully: Windows has shut down after \(Int(Date().timeIntervalSince(started))) seconds")
                    Announcer.shared.announce("\(configuration.name) has shut down.", tone: .success)
                }
                return
            case .error:
                // handleQEMUProcessExit has already announced the failure.
                AVMLog.write("VMSession: stopGracefully: VM ended in an error state during shutdown")
                return
            default:
                break
            }
            // A warning first (2026-10-28, fourth audit): the agent's shut down
            // closes apps without saving, and Windows may be waiting on a
            // "save changes?" question nobody heard.
            if !warnedAboutAgent, Date().timeIntervalSince(started) >= agentAfter - 15 {
                warnedAboutAgent = true
                // Only a promise AVM can keep (2026-10-28, fifth audit): with
                // no agent answering, nothing happened at 60 seconds, and
                // the user waited for a shut down that never came.
                let answers = await manager.guestAgentAnswers()
                // Not once it has stopped (2026-10-29, sixth audit): the ping
                // can take seconds, and "still shutting down" came right
                // before "has shut down".
                guard case .stopping = manager.state else { continue }
                if answers {
                    agentAt = Date().timeIntervalSince(started) + 15
                    Announcer.shared.announce("\(configuration.name) is still shutting down. It may be asking whether to save your work; enter it to answer. In 15 seconds AVM makes it shut down, closing its apps without saving.", tone: .info)
                } else {
                    askedAgent = true
                    Announcer.shared.announce("\(configuration.name) is still shutting down. It may be asking whether to save your work; enter it to answer. AVM can't hurry it, as its agent isn't answering; if it doesn't finish, Force Stop ends it.", tone: .info)
                }
            }
            if !askedAgent, Date().timeIntervalSince(started) >= agentAt {
                askedAgent = true
                if await manager.askGuestToShutDown() {
                    AVMLog.write("VMSession: stopGracefully: no shutdown after \(Int(agentAfter)) seconds; asked the guest agent")
                    Announcer.shared.announce("\(configuration.name) hasn't shut down yet. AVM is asking it again through its agent, which closes its open apps without saving.", tone: .info)
                } else {
                    AVMLog.write("VMSession: stopGracefully: no shutdown after \(Int(agentAfter)) seconds, and no guest agent to ask")
                    // The promise was made (seventh audit): say it can't be kept.
                    if warnedAboutAgent, case .stopping = manager.state {
                        Announcer.shared.announce("\(configuration.name)'s agent stopped answering, so AVM can't hurry it. If it doesn't finish, Force Stop ends it.", tone: .info)
                    }
                }
            }
            if !reminded, Date().timeIntervalSince(started) >= reminderAfter {
                reminded = true
                AVMLog.write("VMSession: stopGracefully: still shutting down after \(Int(reminderAfter)) seconds; reminded the user, still waiting")
                Announcer.shared.announce("\(configuration.name) is still shutting down. You can keep waiting, or use Force Stop.", tone: .info)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    enum StopError: LocalizedError {
        case notRunning
        var errorDescription: String? {
            switch self {
            case .notRunning: return "the virtual machine was not running"
            }
        }
    }

    func forceStop() {
        forceStopRequested = true
        manager.forceStopVM()
    }

    func pause() async throws {
        try await manager.pauseVM()
    }

    /// Saves the machine as it is and stops it; the next Start carries on
    /// from there (VMManager.saveStateAndStop, 2026-10-27). Spoken.
    @discardableResult
    func saveAndStop() async -> Bool {
        await manager.saveStateAndStop()
    }

    /// Whether Save is offered: an installed machine on the virtio disk.
    var canSave: Bool { manager.canSaveState }

    /// A restore point taken while it runs, with its memory. Spoken.
    func saveRunningRestorePoint(label: String) async {
        Announcer.shared.announce("Saving the restore point.", tone: .info)
        do {
            _ = try await manager.createRunningRestorePoint(label: label)
            Announcer.shared.announce("Restore point saved: \(label). It keeps open apps too.", tone: .success)
        } catch {
            Announcer.shared.announce("The restore point was not saved. Reason: \(error.localizedDescription)", tone: .failure)
        }
    }

    func resume() async throws {
        try await manager.resumeVM()
    }

    /// Resets the guest via VMManager's QMP `system_reset` — the virtual
    /// reset button (Virtual Machine menu, Cmd-Shift-R). Second member of the
    /// "send system key" family, matching the sendCtrlAltDel forwarder shape
    /// (non-throwing; the manager reports failure via console + log). Also
    /// the recovery experiment for the stochastic firmware reboot wedge
    /// (upstream QEMU/edk2 — UTM issue #7648); see resetVM's doc comment in
    /// VMManager for the full story.
    @discardableResult
    func reset() async -> Bool {
        await manager.resetVM()
    }

    /// Sends Ctrl+Alt+Delete to the guest via VMManager's QMP-level key
    /// injection. This chord CANNOT be typed from the host: Control+Option is
    /// the VoiceOver modifier, so macOS/VoiceOver consumes it before AVM ever
    /// sees a keydown (verified by test — VoiceOver pings and nothing transits,
    /// even with the VO pass-through command). QMP send-key injects at the
    /// virtual-hardware level, bypassing host keyboard forwarding entirely.
    /// First member of the "send system key" family (menu command in the App's
    /// Commands block).
    @discardableResult
    func sendCtrlAltDel() async -> Bool {
        await manager.sendCtrlAltDel()
    }

    // MARK: - Convenience

    var isRunning: Bool { vmState == .running }
    var isPaused:  Bool { vmState == .paused  }
    var isStopped: Bool { vmState == .stopped  }

    var spiceSocketPath: String { manager.spiceSocketPath }
}
