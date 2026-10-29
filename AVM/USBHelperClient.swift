//
//  USBHelperClient.swift
//  AVM
//
//  AVM's side of the root USB helper. Owns registration, the XPC
//  connection, and turns the helper's honest state into speech.
//
//  Decisions of record (handoff 46):
//  1d. Lazy registration. The daemon is registered on the first attach
//      attempt, never at app launch. A person who never touches USB
//      never has a root helper and never sees an approval prompt.
//      Explicit removal control exists. The user-disabled-in-Login-
//      Items state is spoken honestly.
//  1e. Every announcement names its device. Every failure names the
//      failing step and the next action. Outcomes and surprises are
//      announced, not progress chatter.
//  1f. Release is structural: a claim lives only while the XPC
//      connection and the device's stream socket are both alive.
//      Dropping the connection here releases everything.
//
//  Connection lifetime (learned live 2026-09-07): the helper's idle
//  exit waits for zero connections. An open NSXPCConnection from AVM
//  keeps a root process alive with nothing to do. So the connection
//  lives only while a device is attached; one-off calls open it, use
//  it, and drop it.
//
//  Attach ordering (read from the helper's main.swift, 2026-09-12): the
//  helper answers an attach call as soon as its pump is dispatched, and
//  the ATTACHED event follows from the pump later. So a device is held
//  in pendingDevices from the call until its first outcome lands, or
//  the connection would drop between the reply and the event and
//  release the claim structurally (1f) before it ever streamed.
//
//  Lost registration (learned live 2026-09-12): after a run of helper
//  crashes launchd drops the job entirely, while SMAppService keeps
//  reporting .enabled (Login Items remembers the approval). The next
//  XPC call then fails at once with NSXPCConnectionInvalid (4099),
//  "Couldn't communicate with a helper application." So .enabled is
//  not proof that launchd holds the job. On that exact error the
//  client re-registers once and retries; register() on an enabled
//  service re-submits the job to launchd without a new approval.
//
//  Approval prompt (Allison, 2026-09-07): the "needs your approval"
//  moment is a standard NSAlert with an Open Login Items button, not a
//  self-voiced paragraph. Native dialogs are VoiceOver territory;
//  self-voicing is for when VoiceOver may be off or a dialog makes no
//  sense. The one-line "approved, continuing" stays spoken because at
//  that moment the person is in System Settings, not in AVM.
//
//  Status note (learned 2026-09-07): SMAppService reports .notFound for
//  a daemon macOS has never been told about. The docs call that an
//  error; Apple DTS says it is the normal pre-registration state. So
//  .notFound is a reason to register, and only a .notFound that
//  survives a register() attempt means the helper is really missing.
//
//  Announcement wording is provisional pending Allison's voice pass.
//

import AppKit
import Combine
import Foundation
import ServiceManagement

// MARK: - Callback receiver (off the main actor by design)

/// The object the helper calls back into. XPC invokes it on its own
/// thread, so it is nonisolated and hops to the main actor before
/// anything is announced.
nonisolated final class USBHelperCallbackReceiver: NSObject, AVMUSBHelperClientProtocol {
    func stateChanged(_ device: AVMUSBDeviceIdentity,
                      state: AVMUSBDeviceState,
                      detail: String?) {
        Task { @MainActor in
            USBHelperClient.shared.handleStateChanged(device, state: state, detail: detail)
        }
    }

    // The keyboard for Windows (2026-10-26). The main queue, not Tasks:
    // it keeps key presses in the exact order they were typed.
    func keyboardKey(usage: Int, pressed: Bool) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { WindowsKeyboard.shared.key(usage: usage, pressed: pressed) }
        }
    }

    func keyboardState(_ keyboardID: String, held: Bool, detail: String?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { WindowsKeyboard.shared.stateChanged(keyboardID, held: held, detail: detail) }
        }
    }

    func bluetoothState(_ id: String, held: Bool, detail: String?) {
        Task { @MainActor in BluetoothDevices.shared.helperLetGo(id, detail: detail) }
    }
}

/// A Bluetooth HID device the helper can see (BluetoothHold.swift).
struct BluetoothDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// braille, controller, keyboard, pointer, remote or other.
    let kind: String
    let vendor: Int
    let product: Int
    let descriptor: Data
}

// MARK: - Errors

nonisolated enum USBHelperError: Error, CustomStringConvertible {
    case notEnabled(USBHelperClient.HelperStatus)
    case xpc(String)
    /// XPC reported NSXPCConnectionInvalid (4099): launchd has no job
    /// for the Mach service right now, whatever Login Items says.
    case helperUnavailable(String)
    /// The helper answered and said no. Step names where, detail why.
    case helper(step: String, detail: String)

    var description: String {
        switch self {
        case .notEnabled(let s): return "helper not enabled (\(s.rawValue))"
        case .xpc(let s): return s
        case .helperUnavailable(let s): return "helper unavailable: \(s)"
        case .helper(let step, let detail): return "\(step): \(detail)"
        }
    }

    /// Sorts an XPC error handler's NSError into the two cases above.
    static func fromXPC(_ error: Error) -> USBHelperError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == 4099 {
            return .helperUnavailable(ns.localizedDescription)
        }
        return .xpc(ns.localizedDescription)
    }
}

// MARK: - Client

@MainActor
final class USBHelperClient: NSObject, ObservableObject {
    static let shared = USBHelperClient()

    /// SMAppService.Status, in AVM's own words.
    enum HelperStatus: String {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unknown
    }

    @Published private(set) var status: HelperStatus = .unknown

    /// Devices the helper has told us are attached. Drives connection
    /// lifetime: empty set means the connection is dropped after use.
    @Published private(set) var attachedDevices: Set<AVMUSBDeviceIdentity> = []

    /// Devices with an attach in flight: the call has been made and no
    /// outcome (attached or failed) has arrived yet. Holds the
    /// connection open across that gap. See the header note.
    private var pendingDevices: Set<AVMUSBDeviceIdentity> = []

    /// An attach failure can reach AVM twice: as a stateChanged event
    /// and as the call's own reply, in either order. Whichever arrives
    /// first speaks; the other stays quiet. Cleared on the next attach.
    private var announcedAttachFailures: Set<AVMUSBDeviceIdentity> = []

    /// Devices USBPlugPrompt's send gate is handling, by
    /// USBRedirectController.followKey, so every address of the same
    /// physical device counts. Their lines are logged, not spoken; the
    /// gate speaks one outcome itself (USB 2c, 2026-10-18).
    private var quietKeys: Set<String> = []

    func setQuiet(_ device: AVMUSBDeviceIdentity, _ quiet: Bool) {
        let key = USBRedirectController.followKey(device)
        if quiet { quietKeys.insert(key) } else { quietKeys.remove(key) }
    }

    func isQuiet(_ device: AVMUSBDeviceIdentity) -> Bool {
        quietKeys.contains(USBRedirectController.followKey(device))
    }

    /// Devices the helper reported attached at some point since their
    /// latest attach began. Unlike attachedDevices, an unplug doesn't
    /// clear it, so the controller can tell a device that left Windows
    /// from one whose attach never finished (thumb drive, 2026-10-18).
    private var reached: Set<AVMUSBDeviceIdentity> = []

    func reachedWindows(_ device: AVMUSBDeviceIdentity) -> Bool {
        reached.contains(device)
    }

    /// Called on the main actor for every ending the helper reports
    /// (released, failed, yanked) so USBRedirectController can take the
    /// device's QEMU port back. Added 2026-09-12 (increment 2a).
    var deviceEnded: ((AVMUSBDeviceIdentity, AVMUSBDeviceState) -> Void)?

    private var connection: NSXPCConnection?
    private let receiver = USBHelperCallbackReceiver()
    private var approvalWatch: Task<Void, Never>?

    private let logCategory = "USBHelper"

    private override init() {
        super.init()
    }

    private var service: SMAppService {
        SMAppService.daemon(plistName: AVMUSBHelperNames.launchdPlistName)
    }

    // MARK: Status

    @discardableResult
    func refreshStatus() -> HelperStatus {
        let s: HelperStatus
        switch service.status {
        case .notRegistered: s = .notRegistered
        case .enabled: s = .enabled
        case .requiresApproval: s = .requiresApproval
        case .notFound: s = .notFound
        @unknown default: s = .unknown
        }
        status = s
        return s
    }

    // MARK: Registration (1d: lazy, on first use)

    /// Make sure the helper is registered and approved. Returns true
    /// when it can be used right now. Every false path has already
    /// been surfaced with the next action.
    func ensureRegistered() -> Bool {
        switch refreshStatus() {
        case .enabled:
            return true

        case .requiresApproval:
            presentApprovalDialog()
            return false

        case .notRegistered, .notFound, .unknown:
            do {
                try service.register()
                log("ensureRegistered: register() returned without error")
            } catch {
                log("ensureRegistered: register() threw: \(error)")
            }
            // register() may succeed outright, or leave the daemon
            // waiting on Login Items approval, or fail. Read back
            // what actually happened rather than trusting the throw.
            switch refreshStatus() {
            case .enabled:
                announce("USB helper registered and enabled.", tone: .success)
                return true
            case .requiresApproval:
                presentApprovalDialog()
                return false
            case .notFound:
                log("ensureRegistered: still notFound after register(); helper plist or binary missing from the bundle")
                announce("The USB helper is missing from this copy of AVM. Step: registering the helper. Next: reinstall AVM.", tone: .failure)
                return false
            case .notRegistered, .unknown:
                announce("The USB helper could not be registered with macOS. Step: registering the helper. Next: check the diagnostic log and report this.", tone: .failure)
                return false
            }
        }
    }

    /// Explicit removal control (1d). Drops the connection first so
    /// every claim releases structurally before the daemon goes away.
    func unregister() {
        disconnect()
        approvalWatch?.cancel()
        do {
            try service.unregister()
            log("unregister: done")
            refreshStatus()
            announce("USB helper removed. Any redirected devices have been returned to the Mac.", tone: .info)
        } catch {
            log("unregister: threw: \(error)")
            announce("The USB helper could not be removed. Step: unregistering the helper. Next: remove AVM from Login Items in System Settings.", tone: .failure)
        }
    }

    /// The recovery for a dropped launchd job. Returns true when the
    /// service reads .enabled afterwards and a retry is worth making.
    private func recoverLostRegistration() -> Bool {
        log("XPC says the service is gone while Login Items says enabled; re-registering with launchd")
        do {
            try service.register()
            log("recoverLostRegistration: register() returned without error")
        } catch {
            log("recoverLostRegistration: register() threw: \(error)")
        }
        let s = refreshStatus()
        log("recoverLostRegistration: status now \(s.rawValue)")
        return s == .enabled
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Standard alert. VoiceOver reads it; the default button goes
    /// straight to the right pane. The approval watch starts either
    /// way, so approving later still gets the spoken confirmation.
    private var approvalDialogShowing = false
    private func presentApprovalDialog() {
        log("registration requires approval in Login Items; presenting dialog")
        startApprovalWatch()
        // One at a time (2026-10-28, fourth audit): requests arriving
        // together (a keyboard for Windows and a plug-in at a start) stacked
        // two or three identical alerts, each read and dismissed in turn.
        guard !approvalDialogShowing else { return }
        approvalDialogShowing = true
        defer { approvalDialogShowing = false }
        let alert = NSAlert()
        alert.messageText = "AVM needs permission to run its USB helper"
        alert.informativeText = "macOS requires your approval before AVM can pass USB devices to a virtual machine. In System Settings, under General, then Login Items and Extensions, allow AVM to run in the background. AVM will announce when the helper is approved."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            log("approval dialog: Open Login Items")
            openLoginItems()
        } else {
            log("approval dialog: Not Now")
        }
    }

    /// Waits, up to `limit`, for the helper to be approved, checking every
    /// 2 seconds while `keepWaiting` is true. True once it's enabled.
    ///
    /// For a send that asked for the approval (2026-10-27, a tester's
    /// keyboard): it used to fail and be forgotten, so after "USB helper
    /// approved, continuing" nothing continued and the keyboard stayed on
    /// the Mac until it was plugged in again. The send now waits here and
    /// goes ahead once the approval lands.
    func waitForApproval(limit: TimeInterval = 300, while keepWaiting: () -> Bool) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < limit, keepWaiting() {
            if refreshStatus() == .enabled { return true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return refreshStatus() == .enabled
    }

    // MARK: Bluetooth devices (2026-10-27)

    func listBluetoothDevices() async -> Result<[BluetoothDeviceInfo], USBHelperError> {
        guard ensureRegistered() else { return .failure(.notEnabled(status)) }
        await ensureCurrentHelper()
        let c = connect()
        let result: Result<[BluetoothDeviceInfo], USBHelperError> = await withCheckedContinuation { cont in
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                cont.resume(returning: .failure(USBHelperError.fromXPC(error)))
            } as? AVMUSBHelperProtocol
            guard let proxy else { cont.resume(returning: .failure(.xpc("could not build the helper proxy"))); return }
            proxy.listBluetoothDevices { list in
                cont.resume(returning: .success(list.compactMap { entry in
                    guard let id = entry["id"] as? String, let descriptor = entry["descriptor"] as? Data else { return nil }
                    return BluetoothDeviceInfo(id: id, name: entry["name"] as? String ?? "Bluetooth device",
                                               kind: entry["kind"] as? String ?? "other",
                                               vendor: (entry["vendor"] as? NSNumber)?.intValue ?? 0,
                                               product: (entry["product"] as? NSNumber)?.intValue ?? 0,
                                               descriptor: descriptor)
                }))
            }
        }
        disconnectIfIdle()
        return result
    }

    func holdBluetooth(_ id: String, socketPath: String, peerPID: Int) async -> Result<Void, USBHelperError> {
        guard ensureRegistered() else { return .failure(.notEnabled(status)) }
        await ensureCurrentHelper()
        bluetoothHeld.insert(id)
        let c = connect()
        let result: Result<Void, USBHelperError> = await withCheckedContinuation { cont in
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                cont.resume(returning: .failure(USBHelperError.fromXPC(error)))
            } as? AVMUSBHelperProtocol
            guard let proxy else { cont.resume(returning: .failure(.xpc("could not build the helper proxy"))); return }
            proxy.holdBluetoothDevice(id, streamSocketPath: socketPath, peerPID: peerPID) { ok, reason in
                cont.resume(returning: ok ? .success(()) : .failure(.helper(step: "taking the Bluetooth device", detail: reason ?? "")))
            }
        }
        if case .failure = result {
            bluetoothHeld.remove(id)
            disconnectIfIdle()
        }
        return result
    }

    func releaseBluetooth(_ id: String) async {
        guard bluetoothHeld.contains(id), let c = connection else { bluetoothHeld.remove(id); return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let proxy = c.remoteObjectProxyWithErrorHandler { _ in cont.resume() } as? AVMUSBHelperProtocol
            guard let proxy else { cont.resume(); return }
            proxy.releaseBluetoothDevice(id) { cont.resume() }
        }
        bluetoothHeld.remove(id)
        disconnectIfIdle()
    }

    /// The helper let a device go by itself (it disconnected, or QEMU closed).
    func forgetBluetooth(_ id: String) {
        bluetoothHeld.remove(id)
        disconnectIfIdle()
    }

    /// Before Sparkle relaunches AVM (2026-10-28): asks the helper to exit
    /// and waits for its answer, at most `wait`. Sparkle calls its delegate
    /// on the main thread, so this uses a connection of its own and never
    /// the main actor (a MainActor task can't run while the main thread
    /// waits).
    nonisolated static func askHelperToExitNow(wait: TimeInterval = 3) {
        let connection = NSXPCConnection(machServiceName: AVMUSBHelperNames.machServiceName, options: .privileged)
        connection.remoteObjectInterface = AVMUSBHelperInterfaces.helper()
        connection.resume()
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? AVMUSBHelperProtocol
        if let proxy {
            proxy.restart { done.signal() }
            _ = done.wait(timeout: .now() + wait)
        }
        connection.invalidate()
    }

    /// A helper from before an update (2026-10-28, code review): it keeps
    /// running for its idle grace period, and the new AVM would talk to
    /// it. Once per run, before a device is taken: a helper answering with
    /// another version is asked to exit, so launchd starts this build's.
    /// One check per run, which every caller waits for (2026-10-28, fourth
    /// audit): set before its await, the flag let a second request go to
    /// the stale helper, which the first then restarted under it.
    private var helperCheck: Task<Void, Never>?
    func ensureCurrentHelper() async {
        if let helperCheck { return await helperCheck.value }
        let check = Task { await self.checkHelperVersion() }
        helperCheck = check
        await check.value
    }

    private func checkHelperVersion() async {
        // The helper answers "service-name version" (2026-10-28, second
        // review: compared whole, it never matched, and every run restarted
        // the helper at its first device). The connection stays up: the
        // hold that follows uses it, and a disconnect here fired the
        // "helper lost" handlers into that hold.
        guard case .success(let answer) = await fetchHelperVersion(keepConnection: true) else { return }
        let version = answer.split(separator: " ").last.map(String.init) ?? answer
        guard version != AVMUSBHelperNames.helperBuildVersion else { return }
        log("the running helper is \(version), this AVM expects \(AVMUSBHelperNames.helperBuildVersion); restarting it")
        _ = await restartHelper()
    }

    /// Restart USB Helper (2026-10-27): asks the helper to exit, then
    /// calls it again, which makes launchd start a fresh one, and returns
    /// that one's version. The caller returns devices to the Mac first.
    func restartHelper() async -> Result<String, USBHelperError> {
        guard ensureRegistered() else { return .failure(.notEnabled(status)) }
        log("restart: asking the helper to exit")
        let c = connect()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let proxy = c.remoteObjectProxyWithErrorHandler { _ in cont.resume() } as? AVMUSBHelperProtocol
            guard let proxy else { cont.resume(); return }
            proxy.restart { cont.resume() }
        }
        try? await Task.sleep(for: .seconds(2))
        let fresh = connect()
        let version: String? = await withCheckedContinuation { cont in
            let proxy = fresh.remoteObjectProxyWithErrorHandler { _ in cont.resume(returning: nil) } as? AVMUSBHelperProtocol
            guard let proxy else { cont.resume(returning: nil); return }
            proxy.helperVersion { cont.resume(returning: $0) }
        }
        disconnectIfIdle()
        guard let version else {
            log("restart: the helper didn't answer afterwards")
            return .failure(.xpc("the helper didn't start again"))
        }
        log("restart: a fresh helper answered (\(version))")
        return .success(version)
    }

    /// Polls status until the approval lands, then says so (1e:
    /// "USB helper approved, continuing" is spoken so the person
    /// standing in System Settings hears the handshake complete).
    private func startApprovalWatch() {
        approvalWatch?.cancel()
        approvalWatch = Task { @MainActor in
            for _ in 0..<150 { // 5 minutes at 2 s
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if refreshStatus() == .enabled {
                    log("approval watch: helper enabled")
                    announce("USB helper approved, continuing.", tone: .success)
                    return
                }
            }
            log("approval watch: gave up after 5 minutes")
        }
    }

    // MARK: Connection

    private func connect() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: AVMUSBHelperNames.machServiceName,
                                options: .privileged)
        c.remoteObjectInterface = AVMUSBHelperInterfaces.helper()
        c.exportedInterface = AVMUSBHelperInterfaces.client()
        c.exportedObject = receiver
        c.invalidationHandler = { [weak self, weak c] in
            Task { @MainActor in
                // Only for the connection it belongs to (2026-10-28, second
                // review): an old one's late handler tore down a new hold.
                guard let self, let c, self.connection === c else { return }
                self.log("connection invalidated")
                self.connection = nil
                self.keyboardHelperLost()
                self.devicesHelperLost()
                self.bluetoothHeld.removeAll()
                BluetoothDevices.shared.helperLost()
            }
        }
        c.interruptionHandler = { [weak self, weak c] in
            Task { @MainActor in
                guard let self, let c, self.connection === c else { return }
                self.log("connection interrupted (helper exited or crashed)")
                self.keyboardHelperLost()
                self.devicesHelperLost()
                self.bluetoothHeld.removeAll()
                BluetoothDevices.shared.helperLost()
            }
        }
        c.resume()
        connection = c
        log("connection opened to \(AVMUSBHelperNames.machServiceName)")
        return c
    }

    /// Dropping the connection is the release path for every device
    /// at once (1f). The helper sees the drop and lets go.
    func disconnect() {
        guard let c = connection else { return }
        log("disconnecting")
        c.invalidate()
        connection = nil
    }

    /// The lifetime rule: no attached or pending devices, no
    /// connection. Called after every one-off call and after every
    /// state event.
    /// A keyboard for Windows is wanted or held (WindowsKeyboard.swift);
    /// the connection is what keeps it, so it stays open meanwhile.
    var keyboardActive = false
    /// Bumped by every holdKeyboard (2026-10-26, keyboard audit): a release
    /// still waiting on the helper's answer when a new hold starts (a quick
    /// SPICE reconnect) must not then mark the keyboard idle and drop the
    /// connection, which would make the helper let go of the new hold.
    private var keyboardGeneration = 0

    /// Bluetooth devices held for a machine (BluetoothDevices.swift): the
    /// helper lets them go when this connection ends, so it stays open.
    private var bluetoothHeld: Set<String> = []

    private func disconnectIfIdle() {
        if attachedDevices.isEmpty && pendingDevices.isEmpty && !keyboardActive && bluetoothHeld.isEmpty {
            disconnect()
        }
    }

    // MARK: Calls

    /// Ask the helper who it is. The first end-to-end proof: register,
    /// launchd start, code-signing gate, reply.
    func fetchHelperVersion(retrying: Bool = false, keepConnection: Bool = false) async -> Result<String, USBHelperError> {
        guard ensureRegistered() else {
            return .failure(.notEnabled(status))
        }
        let c = connect()
        let result: Result<String, USBHelperError> = await withCheckedContinuation { cont in
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                cont.resume(returning: .failure(USBHelperError.fromXPC(error)))
            } as? AVMUSBHelperProtocol
            guard let proxy else {
                cont.resume(returning: .failure(.xpc("could not build the helper proxy")))
                return
            }
            proxy.helperVersion { version in
                cont.resume(returning: .success(version))
            }
        }
        if !keepConnection { disconnectIfIdle() }
        if case .failure(.helperUnavailable) = result, retrying == false, recoverLostRegistration() {
            return await fetchHelperVersion(retrying: true)
        }
        return result
    }

    /// Ask the helper to claim `device` and stream it to the QEMU
    /// usbredir socket at `socketPath`. QEMU must already be listening
    /// there (the caller adds the chardev over QMP first).
    ///
    /// A success reply means the claim started, not that it finished:
    /// the outcome arrives as a stateChanged event and is spoken there.
    /// A failure reply is spoken here, once, with its step.
    // MARK: Keyboard for Windows (2026-10-26)

    /// The keyboards connected now, as the helper sees them.
    /// `registering`: set up the helper if it isn't, as using a device does.
    /// Settings lists keyboards when it opens without registering
    /// (2026-10-28, fourth audit): opening a Windows machine's Settings
    /// registered the root helper and showed its approval alert, every
    /// visit, for users who never asked for USB.
    func listKeyboards(registering: Bool = true) async -> Result<[NSDictionary], USBHelperError> {
        if registering {
            guard ensureRegistered() else { return .failure(.notEnabled(status)) }
        } else if refreshStatus() != .enabled {
            return .failure(.notEnabled(status))
        }
        let c = connect()
        let result: Result<[NSDictionary], USBHelperError> = await withCheckedContinuation { cont in
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                cont.resume(returning: .failure(USBHelperError.fromXPC(error)))
            } as? AVMUSBHelperProtocol
            guard let proxy else { cont.resume(returning: .failure(.xpc("could not build the helper proxy"))); return }
            proxy.listKeyboards { cont.resume(returning: .success($0)) }
        }
        disconnectIfIdle()
        return result
    }

    func holdKeyboard(_ keyboardID: String) async -> Result<Void, USBHelperError> {
        guard ensureRegistered() else { return .failure(.notEnabled(status)) }
        await ensureCurrentHelper()
        keyboardActive = true
        keyboardGeneration += 1
        let c = connect()
        let result: Result<Void, USBHelperError> = await withCheckedContinuation { cont in
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                cont.resume(returning: .failure(USBHelperError.fromXPC(error)))
            } as? AVMUSBHelperProtocol
            guard let proxy else { cont.resume(returning: .failure(.xpc("could not build the helper proxy"))); return }
            proxy.holdKeyboard(keyboardID) { ok, reason in
                cont.resume(returning: ok ? .success(()) : .failure(.helper(step: "holding the keyboard", detail: reason ?? "")))
            }
        }
        if case .failure = result {
            keyboardActive = false
            disconnectIfIdle()
        }
        return result
    }

    /// The helper went away while it held the keyboard for Windows: the
    /// kernel has given the keyboard back to macOS, so Windows must let go
    /// of any key still down, and AVM asks again (2026-10-26, keyboard
    /// audit; this used to only log).
    /// Devices the helper held are the Mac's again once it's gone.
    private func devicesHelperLost() {
        guard !attachedDevices.isEmpty || !pendingDevices.isEmpty else { return }
        attachedDevices.removeAll()
        pendingDevices.removeAll()
        USBRedirectController.shared.helperLost()
    }

    private func keyboardHelperLost() {
        guard keyboardActive else { return }
        keyboardActive = false
        WindowsKeyboard.shared.helperLost()
    }

    func releaseKeyboard() async {
        guard keyboardActive, let c = connection else { keyboardActive = false; return }
        let generation = keyboardGeneration
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let proxy = c.remoteObjectProxyWithErrorHandler { _ in cont.resume() } as? AVMUSBHelperProtocol
            guard let proxy else { cont.resume(); return }
            proxy.releaseKeyboard { cont.resume() }
        }
        guard generation == keyboardGeneration else { return }
        keyboardActive = false
        disconnectIfIdle()
    }

    func attach(_ device: AVMUSBDeviceIdentity,
                socketPath: String,
                peerPID: Int,
                retrying: Bool = false) async -> Result<Void, USBHelperError> {
        guard ensureRegistered() else {
            return .failure(.notEnabled(status))
        }
        await ensureCurrentHelper()
        announcedAttachFailures.remove(device)
        reached.remove(device)
        pendingDevices.insert(device)
        let c = connect()
        log("attach: \(device.description) -> \(socketPath)")

        // 1e: a still-working line if nothing has resolved in ~2 s.
        let stillWorking = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, Task.isCancelled == false else { return }
            if self.pendingDevices.contains(device), self.isQuiet(device) == false {
                self.announce("Still attaching \(device.displayName).", tone: .info)
            }
        }

        let result: Result<Void, USBHelperError> = await withCheckedContinuation { cont in
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                cont.resume(returning: .failure(USBHelperError.fromXPC(error)))
            } as? AVMUSBHelperProtocol
            guard let proxy else {
                cont.resume(returning: .failure(.xpc("could not build the helper proxy")))
                return
            }
            proxy.attach(device, streamSocketPath: socketPath, peerPID: peerPID) { ok, step, detail in
                if ok {
                    cont.resume(returning: .success(()))
                } else {
                    cont.resume(returning: .failure(.helper(step: step ?? "unknown step",
                                                            detail: detail ?? "")))
                }
            }
        }

        switch result {
        case .success:
            log("attach: helper accepted \(device.description); waiting for the attached event")
        case .failure(let error):
            stillWorking.cancel()
            pendingDevices.remove(device)
            log("attach: helper refused \(device.description): \(error)")
            disconnectIfIdle()
            if case .helperUnavailable = error, retrying == false, recoverLostRegistration() {
                return await attach(device, socketPath: socketPath, peerPID: peerPID, retrying: true)
            }
            if isQuiet(device) {
                log("attach: failure not spoken; the send gate is handling \(device.description)")
            } else if case .helper(let step, _) = error {
                announceAttachFailure(device, step: step)
            } else {
                announce("Could not reach the USB helper to attach \(device.displayName). Step: XPC call. Next: check Login Items, then the diagnostic log.", tone: .failure)
            }
        }
        return result
    }

    /// Ask the helper to release `device`. The helper answers after its
    /// pump has finished and the device is back with macOS (about two
    /// seconds; libusb re-enumerates and reattaches kernel drivers), or
    /// answers false after ten seconds if the pump never came back. The
    /// released event is spoken by handleStateChanged; this reply is
    /// only logged, and a refusal is spoken with its reason.
    /// quiet: log a failure instead of speaking it. Used when the device
    /// has already vanished and the unplug has been spoken.
    func detach(_ device: AVMUSBDeviceIdentity, quiet: Bool = false) async -> Result<Void, USBHelperError> {
        guard ensureRegistered() else {
            return .failure(.notEnabled(status))
        }
        let c = connect()
        log("detach: \(device.description)")

        let result: Result<Void, USBHelperError> = await withCheckedContinuation { cont in
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                cont.resume(returning: .failure(USBHelperError.fromXPC(error)))
            } as? AVMUSBHelperProtocol
            guard let proxy else {
                cont.resume(returning: .failure(.xpc("could not build the helper proxy")))
                return
            }
            proxy.detach(device) { ok, detail in
                if ok {
                    cont.resume(returning: .success(()))
                } else {
                    cont.resume(returning: .failure(.helper(step: "release", detail: detail ?? "")))
                }
            }
        }

        switch result {
        case .success:
            log("detach: helper released \(device.description)")
        case .failure(let error):
            log("detach: \(device.description): \(error)")
            if quiet == false {
                announce("Could not release \(device.displayName). Reason: \(error). Next: unplug and replug the device if the Mac does not see it.", tone: .failure)
            }
        }
        disconnectIfIdle()
        return result
    }

    /// Clears a device that vanished without a helper report, so a late
    /// yanked or released report for it is logged, not spoken again.
    func forget(_ device: AVMUSBDeviceIdentity) {
        pendingDevices.remove(device)
        attachedDevices.remove(device)
        log("forget: \(device.description); it vanished with no helper report")
    }

    /// Speaks an attach failure exactly once per attempt, whichever
    /// path (event or reply) reports it first.
    private func announceAttachFailure(_ device: AVMUSBDeviceIdentity, step: String) {
        guard isQuiet(device) == false else {
            log("attach failure not spoken; the send gate is handling \(device.description)")
            return
        }
        guard announcedAttachFailures.insert(device).inserted else { return }
        announce("Could not attach \(device.displayName). Step: \(step). Next: check that no other app is using the device and try again.", tone: .failure)
    }

    // MARK: State events (1e)

    func handleStateChanged(_ device: AVMUSBDeviceIdentity,
                            state: AVMUSBDeviceState,
                            detail: String?) {
        let name = device.displayName
        log("stateChanged: \(device.description) -> \(state) \(detail ?? "")")
        switch state {
        case .attaching, .releasing:
            // Progress, not outcome. The attach call site owns the
            // ~2 s still-working line.
            break
        case .attached:
            pendingDevices.remove(device)
            attachedDevices.insert(device)
            reached.insert(device)
            if isQuiet(device) {
                log("attached: not spoken; the send gate is handling \(device.description)")
            } else {
                // The machine it went to (2026-10-28, fourth audit): an
                // attach that waited for approval landed after the user had
                // moved to another machine, and the front one was named.
                let machine = USBRedirectController.shared.machine(for: device)?.machineName ?? VMManager.currentGuestName
                announce("\(name) is now in \(machine).", tone: .success)
            }
        case .released:
            // One unplug reports yanked, then released, 0.03 s apart
            // (log, 2026-10-12). Yanked already spoke and cleared the
            // device, so released is spoken only for a device that was
            // still attached or attaching, as after Detach USB Device.
            let wasInWindows = attachedDevices.contains(device) || pendingDevices.contains(device)
            pendingDevices.remove(device)
            attachedDevices.remove(device)
            if wasInWindows, isQuiet(device) {
                log("released: not spoken; the send gate is handling \(device.description)")
            } else if wasInWindows {
                announce("\(name) returned to the Mac.", tone: .info)
            } else {
                log("released after unplug: \(device.description); already spoken, not repeated")
            }
            deviceEnded?(device, state)
        case .failed:
            pendingDevices.remove(device)
            attachedDevices.remove(device)
            announceAttachFailure(device, step: detail ?? "unknown step")
            deviceEnded?(device, state)
        case .yanked:
            let stillKnown = attachedDevices.contains(device) || pendingDevices.contains(device)
            pendingDevices.remove(device)
            attachedDevices.remove(device)
            // Unplugging is normal in plug and play, so this uses the
            // ordinary sound, not the failure sound that cuts off other
            // speech (Allison, 2026-10-12). The VM has been told already.
            // A device AVM already cleaned up after it vanished was
            // spoken then, so a late report is only logged.
            if stillKnown, isQuiet(device) {
                log("yanked: not spoken; the send gate is handling \(device.description)")
            } else if stillKnown {
                announce("\(name) was unplugged.", tone: .info)
            } else {
                log("yanked after cleanup: \(device.description); already spoken, not repeated")
            }
            deviceEnded?(device, state)
        @unknown default:
            log("stateChanged: unknown state raw value \(state.rawValue)")
        }
        disconnectIfIdle()
    }

    // MARK: Plumbing

    private func announce(_ message: String, tone: Announcer.Tone) {
        Announcer.shared.announce(message, tone: tone)
    }

    private func log(_ message: String) {
        AVMLog.write("USBHelperClient: \(message)", category: logCategory)
    }
}
