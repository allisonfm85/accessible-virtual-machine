//
//  main.swift
//  AVMUSBHelper
//
//  The root USB helper for AVM. Runs as a launchd daemon registered
//  by AVM through SMAppService, on demand, and exits when idle.
//
//  Scope contract (handoff 46, decision 1b): claim, stream, release,
//  report. Nothing else. No enumeration, no policy, no persistence,
//  no speech. AVM does the talking. This process supplies honest
//  state.
//
//  Increment 1 (2026-09-12): attach, detach and status are real.
//  The claim / stream / release path is probe3's, compiled in as
//  usbstream.c and reached through the bridging header. Each device
//  gets its own serial queue that runs the blocking pump; state
//  changes go back to AVM through the client protocol.
//
//  The listener, the code signing gate and the idle exit were proven
//  live on 2026-09-07 and are unchanged.
//
//  Log levels: lifecycle lines are .default so `log show` keeps them.
//  .info is dropped by default and was invisible in the first proof.
//
import Foundation
import os.log
// MARK: - Identity
/// Bumped whenever the helper's behavior changes so AVM can tell a
/// stale helper from a current one.
let helperBuildVersion = "0.2.0-stream"
let log = OSLog(subsystem: AVMUSBHelperNames.machServiceName, category: "helper")
/// usbredir debug logging for every stream. Off in normal use: it is
/// chatty, and a root process should not narrate USB traffic into the
/// unified log by default.
let verboseStreamLogging = false
/// Who may talk to this helper. Debug builds of AVM are signed by the
/// development team; shipped builds by the Developer ID team. A
/// release helper never trusts the development team.
#if DEBUG
let clientTeamID = "4NZJSBJ32X"
#else
let clientTeamID = "W7VP84KBHP"
#endif
let clientRequirement = "anchor apple generic"
    + " and identifier \"\(AVMUSBHelperNames.clientBundleIdentifier)\""
    + " and certificate leaf[subject.OU] = \"\(clientTeamID)\""
// MARK: - Idle exit
/// The helper exits after this long with no connections and no
/// claimed devices. launchd starts it again on the next XPC call.
let idleGracePeriod: TimeInterval = 30
final class IdleWatch {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "idle")
    private(set) var connectionCount = 0
    private(set) var claimedDeviceCount = 0
    func connectionOpened() {
        queue.async {
            self.connectionCount += 1
            self.cancelTimer()
        }
    }
    func connectionClosed() {
        queue.async {
            self.connectionCount = max(0, self.connectionCount - 1)
            self.armIfIdle()
        }
    }
    func devicesChanged(count: Int) {
        queue.async {
            self.claimedDeviceCount = count
            if count > 0 {
                self.cancelTimer()
            } else {
                self.armIfIdle()
            }
        }
    }
    func armIfIdle() {
        guard connectionCount == 0, claimedDeviceCount == 0 else { return }
        cancelTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + idleGracePeriod)
        t.setEventHandler {
            os_log("idle for %{public}.0f s with no connections and no devices; exiting", log: log, type: .default, idleGracePeriod)
            avm_usb_runtime_stop()
            exit(0)
        }
        t.resume()
        timer = t
    }
    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
let idle = IdleWatch()
// MARK: - Device registry
/// One held device: its identity, where it is in its life, the C
/// stream behind it, and which AVM connection asked for it.
final class DeviceEntry {
    let device: AVMUSBDeviceIdentity
    let socketPath: String
    /// Serial queue that runs this device's pump. One per device so a
    /// blocked pump never stalls another device or the registry.
    let queue: DispatchQueue
    var state: AVMUSBDeviceState = .attaching
    var stream: OpaquePointer?
    /// What ended the stream, if anything did, so the final released
    /// report can say why.
    var endDetail: String?
    weak var connection: NSXPCConnection?
    /// A detach waiting for the pump to finish.
    var detachReply: ((Bool, String?) -> Void)?
    var detachTimeout: DispatchWorkItem?
    init(device: AVMUSBDeviceIdentity, socketPath: String, connection: NSXPCConnection?) {
        self.device = device
        self.socketPath = socketPath
        self.connection = connection
        self.queue = DispatchQueue(label: "device." + device.vidPidString)
    }
}
/// Everything the helper holds. All access on `queue`.
final class DeviceRegistry {
    let queue = DispatchQueue(label: "registry")
    private var entries: [AVMUSBDeviceIdentity: DeviceEntry] = [:]
    private var runtimeStarted = false
    // MARK: Attach
    func attach(_ device: AVMUSBDeviceIdentity,
                streamSocketPath: String,
                connection: NSXPCConnection?,
                reply: @escaping (Bool, String?, String?) -> Void) {
        queue.async {
            if let existing = self.entries[device] {
                os_log("attach refused: %{public}@ is already held (state %{public}d)",
                       log: log, type: .default, device.description, existing.state.rawValue)
                reply(false, "already attached",
                      "\(device.displayName) is already attached to a VM.")
                return
            }
            if self.runtimeStarted == false {
                var step = [CChar](repeating: 0, count: 128)
                var detail = [CChar](repeating: 0, count: 512)
                if avm_usb_runtime_start(&step, step.count, &detail, detail.count) != 0 {
                    let s = String(cString: step)
                    let d = String(cString: detail)
                    os_log("USB runtime failed to start at %{public}@: %{public}@", log: log, type: .error, s, d)
                    reply(false, s, d)
                    return
                }
                self.runtimeStarted = true
                os_log("USB runtime started", log: log, type: .default)
            }
            let entry = DeviceEntry(device: device, socketPath: streamSocketPath, connection: connection)
            let context = Unmanaged.passUnretained(entry).toOpaque()
            var step = [CChar](repeating: 0, count: 128)
            var detail = [CChar](repeating: 0, count: 512)
            os_log("attaching %{public}@ to %{public}@", log: log, type: .default,
                   device.description, streamSocketPath)
            let stream = avm_usb_stream_attach(device.vendorID, device.productID,
                                               device.busNumber, device.deviceAddress,
                                               streamSocketPath,
                                               verboseStreamLogging ? 1 : 0,
                                               streamEventCallback, context,
                                               &step, step.count, &detail, detail.count)
            guard let stream else {
                let s = String(cString: step)
                let d = String(cString: detail)
                os_log("attach of %{public}@ failed at %{public}@: %{public}@",
                       log: log, type: .error, device.description, s, d)
                entry.state = .failed
                self.report(entry, detail: "\(s): \(d)")
                reply(false, s, d)
                return
            }
            entry.stream = stream
            self.entries[device] = entry
            idle.devicesChanged(count: self.entries.count)
            // The pump owns the device from here until it returns. The
            // stream is freed only after run has come back, on the same
            // queue, so nothing else can touch a dead pointer.
            entry.queue.async {
                avm_usb_stream_run(stream)
                avm_usb_stream_free(stream)
            }
            reply(true, nil, nil)
        }
    }
    // MARK: Detach
    func detach(_ device: AVMUSBDeviceIdentity,
                reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            guard let entry = self.entries[device], let stream = entry.stream else {
                os_log("detach refused: %{public}@ is not held", log: log, type: .default, device.description)
                reply(false, "\(device.displayName) is not attached, so there is nothing to release.")
                return
            }
            if entry.detachReply != nil {
                reply(false, "\(device.displayName) is already being released.")
                return
            }
            os_log("releasing %{public}@", log: log, type: .default, device.description)
            entry.state = .releasing
            entry.detachReply = reply
            self.report(entry, detail: nil)
            // If the pump does not come back, answer anyway rather than
            // leave AVM waiting forever. The device stays listed as
            // releasing so status stays honest.
            let timeout = DispatchWorkItem {
                if let pending = entry.detachReply {
                    entry.detachReply = nil
                    os_log("release of %{public}@ timed out", log: log, type: .error, device.description)
                    pending(false, "The helper asked the stream for \(device.displayName) to stop, but it did not finish within 10 seconds.")
                }
            }
            entry.detachTimeout = timeout
            self.queue.asyncAfter(deadline: .now() + 10, execute: timeout)
            avm_usb_stream_stop(stream)
        }
    }
    // MARK: Status
    func status(reply: @escaping ([AVMUSBDeviceStatus]) -> Void) {
        queue.async {
            let rows = self.entries.values.map {
                AVMUSBDeviceStatus(device: $0.device, state: $0.state, streamSocketPath: $0.socketPath)
            }
            reply(rows)
        }
    }
    // MARK: Events from the stream
    /// Called on `queue`. `event` is the C event; `step` and `detail`
    /// are already copied out of C memory.
    func handle(entry: DeviceEntry, event: UInt32, step: String, detail: String) {
        switch event {
        case AVM_USB_EVENT_LOG.rawValue:
            let type: OSLogType = (step == "error") ? .error : (step == "warning" ? .default : .info)
            os_log("%{public}@ usbredir %{public}@: %{public}@", log: log, type: type,
                   entry.device.displayName, step, detail)
        case AVM_USB_EVENT_ATTACHED.rawValue:
            os_log("attached %{public}@ (%{public}@)", log: log, type: .default, entry.device.description, detail)
            entry.state = .attached
            report(entry, detail: detail)
        case AVM_USB_EVENT_DEVICE_LOST.rawValue:
            os_log("%{public}@ unplugged while attached", log: log, type: .default, entry.device.description)
            entry.state = .yanked
            entry.endDetail = detail
            report(entry, detail: detail)
        case AVM_USB_EVENT_REJECTED.rawValue, AVM_USB_EVENT_ERROR.rawValue:
            os_log("%{public}@ stream ended at %{public}@: %{public}@", log: log, type: .error,
                   entry.device.description, step, detail)
            entry.state = .failed
            entry.endDetail = "\(step): \(detail)"
            report(entry, detail: entry.endDetail)
        case AVM_USB_EVENT_SOCKET_CLOSED.rawValue:
            os_log("%{public}@: %{public}@", log: log, type: .default, entry.device.description, detail)
            entry.endDetail = detail
        case AVM_USB_EVENT_RELEASED.rawValue:
            os_log("released %{public}@", log: log, type: .default, entry.device.description)
            entry.stream = nil
            entry.state = .released
            entries[entry.device] = nil
            idle.devicesChanged(count: entries.count)
            report(entry, detail: entry.endDetail)
            entry.detachTimeout?.cancel()
            entry.detachTimeout = nil
            if let pending = entry.detachReply {
                entry.detachReply = nil
                pending(true, nil)
            }
        default:
            os_log("unknown stream event %{public}u for %{public}@", log: log, type: .error, event, entry.device.description)
        }
    }
    /// Tell the AVM that asked for this device where it is now.
    private func report(_ entry: DeviceEntry, detail: String?) {
        guard let connection = entry.connection else {
            os_log("no client to report %{public}@ state %{public}d to", log: log, type: .default,
                   entry.device.description, entry.state.rawValue)
            return
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            os_log("stateChanged delivery failed: %{public}@", log: log, type: .error, error.localizedDescription)
        }
        guard let client = proxy as? AVMUSBHelperClientProtocol else {
            os_log("client proxy does not speak the client protocol", log: log, type: .error)
            return
        }
        client.stateChanged(entry.device, state: entry.state, detail: detail)
    }
}
let registry = DeviceRegistry()
/// The one C callback. Fires on the pump thread or the libusb event
/// thread. Copies the strings, then hands off. RELEASED is delivered
/// synchronously so that by the time the pump returns and frees the
/// stream, the registry has already forgotten the pointer.
private func streamEventCallback(_ context: UnsafeMutableRawPointer?,
                                 _ stream: OpaquePointer?,
                                 _ event: avm_usb_event,
                                 _ step: UnsafePointer<CChar>?,
                                 _ detail: UnsafePointer<CChar>?) {
    guard let context else { return }
    let entry = Unmanaged<DeviceEntry>.fromOpaque(context).takeUnretainedValue()
    let stepText = step.map { String(cString: $0) } ?? ""
    let detailText = detail.map { String(cString: $0) } ?? ""
    let code = event.rawValue
    if code == AVM_USB_EVENT_RELEASED.rawValue {
        registry.queue.sync {
            registry.handle(entry: entry, event: code, step: stepText, detail: detailText)
        }
    } else {
        registry.queue.async {
            registry.handle(entry: entry, event: code, step: stepText, detail: detailText)
        }
    }
}
// MARK: - The exported service
final class HelperService: NSObject, AVMUSBHelperProtocol {
    /// The connection this service object belongs to, so stateChanged
    /// callbacks can reach the right AVM.
    weak var connection: NSXPCConnection?
    func attach(_ device: AVMUSBDeviceIdentity,
                streamSocketPath: String,
                reply: @escaping (Bool, String?, String?) -> Void) {
        os_log("attach requested for %{public}@ to %{public}@", log: log, type: .default,
               device.description, streamSocketPath)
        registry.attach(device, streamSocketPath: streamSocketPath, connection: connection, reply: reply)
    }
    func detach(_ device: AVMUSBDeviceIdentity,
                reply: @escaping (Bool, String?) -> Void) {
        os_log("detach requested for %{public}@", log: log, type: .default, device.description)
        registry.detach(device, reply: reply)
    }
    func status(reply: @escaping ([AVMUSBDeviceStatus]) -> Void) {
        os_log("status requested", log: log, type: .default)
        registry.status(reply: reply)
    }
    func helperVersion(reply: @escaping (String) -> Void) {
        os_log("version requested", log: log, type: .default)
        reply(AVMUSBHelperNames.machServiceName + " " + helperBuildVersion)
    }
}
// MARK: - Listener
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // The gate. macOS checks the caller's code signature against
        // this requirement before any message is delivered. A caller
        // that is not AVM, signed by our team, never gets a reply.
        if #available(macOS 13.0, *) {
            newConnection.setCodeSigningRequirement(clientRequirement)
        } else {
            os_log("macOS too old for setCodeSigningRequirement; refusing connection", log: log, type: .error)
            return false
        }
        let service = HelperService()
        service.connection = newConnection
        newConnection.exportedInterface = AVMUSBHelperInterfaces.helper()
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = AVMUSBHelperInterfaces.client()
        newConnection.invalidationHandler = {
            os_log("connection invalidated (pid %{public}d)", log: log, type: .default, newConnection.processIdentifier)
            idle.connectionClosed()
        }
        newConnection.interruptionHandler = {
            os_log("connection interrupted (pid %{public}d)", log: log, type: .default, newConnection.processIdentifier)
        }
        idle.connectionOpened()
        newConnection.resume()
        os_log("accepted connection from pid %{public}d", log: log, type: .default, newConnection.processIdentifier)
        return true
    }
}
// MARK: - Main
os_log("%{public}@ %{public}@ starting as uid %{public}d, requiring team %{public}@",
       log: log, type: .default,
       AVMUSBHelperNames.machServiceName, helperBuildVersion, getuid(), clientTeamID)
let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: AVMUSBHelperNames.machServiceName)
listener.delegate = delegate
listener.resume()
// Nobody may ever connect. Start the idle clock now so a spurious
// launch doesn't leave a root process sitting around.
idle.armIfIdle()
dispatchMain()
