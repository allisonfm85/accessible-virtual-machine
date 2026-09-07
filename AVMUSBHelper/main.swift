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
//  This is the scaffold. attach and detach reply honestly that they
//  are not implemented. status is empty. The listener, the code
//  signing gate and the idle exit are real and can be proven now.
//

import Foundation
import os.log

// MARK: - Identity

/// Bumped whenever the helper's behavior changes so AVM can tell a
/// stale helper from a current one.
let helperBuildVersion = "0.1.0-scaffold"

let log = OSLog(subsystem: AVMUSBHelperNames.machServiceName, category: "helper")

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
            self.armIfIdle()
        }
    }

    func armIfIdle() {
        guard connectionCount == 0, claimedDeviceCount == 0 else { return }
        cancelTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + idleGracePeriod)
        t.setEventHandler {
            os_log("idle for %{public}.0f s with no connections and no devices; exiting", log: log, type: .info, idleGracePeriod)
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

// MARK: - The exported service

final class HelperService: NSObject, AVMUSBHelperProtocol {
    /// The connection this service object belongs to, so stateChanged
    /// callbacks can reach the right AVM.
    weak var connection: NSXPCConnection?

    func attach(_ device: AVMUSBDeviceIdentity,
                streamSocketPath: String,
                reply: @escaping (Bool, String?, String?) -> Void) {
        os_log("attach requested for %{public}@ to %{public}@ — not implemented in scaffold",
               log: log, type: .info, device.description, streamSocketPath)
        reply(false, "helper not implemented yet",
              "The USB helper scaffold accepted the request for \(device.displayName) but cannot claim devices yet.")
    }

    func detach(_ device: AVMUSBDeviceIdentity,
                reply: @escaping (Bool, String?) -> Void) {
        os_log("detach requested for %{public}@ — nothing held", log: log, type: .info, device.description)
        reply(false, "The USB helper scaffold holds no devices, so there is nothing to release.")
    }

    func status(reply: @escaping ([AVMUSBDeviceStatus]) -> Void) {
        os_log("status requested — empty", log: log, type: .info)
        reply([])
    }

    func helperVersion(reply: @escaping (String) -> Void) {
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
            os_log("connection invalidated (pid %{public}d)", log: log, type: .info, newConnection.processIdentifier)
            idle.connectionClosed()
        }
        newConnection.interruptionHandler = {
            os_log("connection interrupted (pid %{public}d)", log: log, type: .info, newConnection.processIdentifier)
        }

        idle.connectionOpened()
        newConnection.resume()
        os_log("accepted connection from pid %{public}d", log: log, type: .info, newConnection.processIdentifier)
        return true
    }
}

// MARK: - Main

os_log("%{public}@ %{public}@ starting as uid %{public}d, requiring team %{public}@",
       log: log, type: .info,
       AVMUSBHelperNames.machServiceName, helperBuildVersion, getuid(), clientTeamID)

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: AVMUSBHelperNames.machServiceName)
listener.delegate = delegate
listener.resume()

// Nobody may ever connect. Start the idle clock now so a spurious
// launch doesn't leave a root process sitting around.
idle.armIfIdle()

dispatchMain()
