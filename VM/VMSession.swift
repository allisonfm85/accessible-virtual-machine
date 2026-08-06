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

    func forceStop() {
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
