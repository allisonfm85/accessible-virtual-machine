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

    // MARK: - Dependencies

    let manager: VMManager
    let configuration: VMConfiguration

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    /// Set by forceStop, so a graceful stop that is still waiting does not
    /// announce a clean shutdown that never happened.
    private var forceStopRequested = false

    // MARK: - Init

    init(configuration: VMConfiguration) {
        self.configuration = configuration
        self.manager = VMManager()
        VMManager.shared = self.manager
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

        manager.$qemuVersion
            .sink { [weak self] newVersion in
                guard let self else { return }
                self.qemuVersion = newVersion
            }
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
    func stopGracefully() async throws {
        forceStopRequested = false
        if case .paused = manager.state {
            AVMLog.write("VMSession: stopGracefully: VM is paused; resuming before shutdown")
            try await manager.resumeVM()
        }
        Announcer.shared.announce("Shutting down Windows.", tone: .info)
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
        let started = Date()
        var reminded = false
        while true {
            switch manager.state {
            case .stopped:
                if forceStopRequested {
                    AVMLog.write("VMSession: stopGracefully: VM was force-stopped during shutdown")
                } else {
                    AVMLog.write("VMSession: stopGracefully: Windows has shut down after \(Int(Date().timeIntervalSince(started))) seconds")
                    Announcer.shared.announce("Windows has shut down.", tone: .success)
                }
                return
            case .error:
                // handleQEMUProcessExit has already announced the failure.
                AVMLog.write("VMSession: stopGracefully: VM ended in an error state during shutdown")
                return
            default:
                break
            }
            if !reminded, Date().timeIntervalSince(started) >= reminderAfter {
                reminded = true
                AVMLog.write("VMSession: stopGracefully: still shutting down after \(Int(reminderAfter)) seconds; reminded the user, still waiting")
                Announcer.shared.announce("Windows is still shutting down. You can keep waiting, or use Force Stop.", tone: .info)
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
