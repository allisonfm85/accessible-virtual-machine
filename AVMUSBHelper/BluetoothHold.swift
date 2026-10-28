// BluetoothHold.swift
// AVMUSBHelper — AVM's privileged helper
//
// Bluetooth devices for a virtual machine (2026-10-27). A Bluetooth
// braille display, game controller or other HID device can't be passed
// through the way a USB one is, so the helper takes it from macOS the way
// it takes a keyboard for Windows (kIOHIDOptionsTypeSeizeDevice, which
// needs a privileged process) and relays its HID reports, both ways, to
// QEMU's usb-hid-bridge device over a socket. The guest sees a USB HID
// device with the Bluetooth device's own report descriptor, and loads the
// driver it would for the real thing.
//
// Frames on the socket (the usb-hid-bridge patch): a type byte, a
// little-endian 16-bit length, that many bytes. 1: an input report, to
// the guest. 2: an output report, from it. 3: a feature report, from it.
//
// The rules, the same as for a keyboard for Windows:
//   - Only for the user at the Mac's screen, and only to a socket in that
//     user's private AVM folder (streamSocketProblem).
//   - Never the Mac's only keyboard or only pointing device.
//   - Let go when AVM asks, when its connection ends, when the device
//     disconnects, or when QEMU closes the socket.
// The helper never logs a report's contents.

import Foundation
import IOKit.hid
import SystemConfiguration
import os.log

final class BluetoothHold {
    static let shared = BluetoothHold()

    let queue = DispatchQueue(label: "bluetooth-hold")

    private final class Held {
        let id: String
        let device: IOHIDDevice
        let socket: Int32
        weak var owner: NSXPCConnection?
        var readSource: DispatchSourceRead?
        var buffer = Data()
        var inputReport: UnsafeMutablePointer<UInt8>
        let inputSize: Int
        let usesReportIDs: Bool
        let ownerUID: uid_t
        init(id: String, device: IOHIDDevice, socket: Int32, owner: NSXPCConnection?, ownerUID: uid_t, inputSize: Int, usesReportIDs: Bool) {
            self.id = id
            self.device = device
            self.socket = socket
            self.owner = owner
            self.ownerUID = ownerUID
            self.inputSize = inputSize
            self.usesReportIDs = usesReportIDs
            inputReport = .allocate(capacity: inputSize)
        }
        deinit { inputReport.deallocate() }
    }
    private var held: [String: Held] = [:]
    /// While anything is held: the device is only for the person at the
    /// screen, as a keyboard for Windows is (2026-10-28, code review: a
    /// fast user switch left it in a background user's machine).
    private var watchTimer: DispatchSourceTimer?

    private func watchWhileHeld() {
        if held.isEmpty {
            watchTimer?.cancel()
            watchTimer = nil
            return
        }
        guard watchTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for entry in self.held.values where !Self.isConsoleUser(entry.ownerUID) {
                os_log("Bluetooth device let go: its user left the screen", log: log, type: .default)
                self.stop(entry, notify: true, detail: "you left the Mac's screen")
            }
        }
        timer.resume()
        watchTimer = timer
    }

    // MARK: Finding devices

    private static func bluetoothDevices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let all = Array(IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [])
        return all.filter { isBluetooth($0) }
    }

    private static func allDevices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        return Array(IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [])
    }

    private static func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }

    private static func isBluetooth(_ device: IOHIDDevice) -> Bool {
        let transport = (property(device, kIOHIDTransportKey) as? String ?? "").lowercased()
        return transport.contains("bluetooth")
    }

    /// Stable across reconnects: vendor, product, then the serial (a
    /// Bluetooth device's is its address) or the location.
    static func identifier(_ device: IOHIDDevice) -> String {
        let vendor = property(device, kIOHIDVendorIDKey) as? Int ?? 0
        let product = property(device, kIOHIDProductIDKey) as? Int ?? 0
        let serial = (property(device, kIOHIDSerialNumberKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "loc\(property(device, kIOHIDLocationIDKey) as? Int ?? 0)"
        let page = property(device, kIOHIDPrimaryUsagePageKey) as? Int ?? 0
        let usage = property(device, kIOHIDPrimaryUsageKey) as? Int ?? 0
        return String(format: "bt:%04x:%04x:%@:%x:%x", vendor, product, serial, page, usage)
    }

    /// What kind of device it is, from its primary usage, for AVM to name.
    private static func kind(_ device: IOHIDDevice) -> String {
        let page = property(device, kIOHIDPrimaryUsagePageKey) as? Int ?? 0
        let usage = property(device, kIOHIDPrimaryUsageKey) as? Int ?? 0
        switch (page, usage) {
        case (0x41, _): return "braille"
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_GamePad),
             (kHIDPage_GenericDesktop, kHIDUsage_GD_Joystick),
             (kHIDPage_GenericDesktop, 0x08): return "controller"     // multi-axis
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard),
             (kHIDPage_GenericDesktop, kHIDUsage_GD_Keypad): return "keyboard"
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Mouse),
             (kHIDPage_GenericDesktop, kHIDUsage_GD_Pointer): return "pointer"
        case (kHIDPage_Consumer, _): return "remote"
        default: return "other"
        }
    }

    func list() -> [NSDictionary] {
        Self.bluetoothDevices().compactMap { device in
            guard let descriptor = Self.property(device, kIOHIDReportDescriptorKey) as? Data, !descriptor.isEmpty else { return nil }
            let id = Self.identifier(device)
            return [
                "id": id,
                "name": Self.property(device, kIOHIDProductKey) as? String ?? "Bluetooth device",
                "kind": Self.kind(device),
                "vendor": NSNumber(value: Self.property(device, kIOHIDVendorIDKey) as? Int ?? 0),
                "product": NSNumber(value: Self.property(device, kIOHIDProductIDKey) as? Int ?? 0),
                "descriptor": descriptor,
                "held": NSNumber(value: queue.sync { held[id] != nil }),
            ] as NSDictionary
        }
    }

    // MARK: Holding

    func hold(_ id: String, streamSocketPath: String, peerPID: Int, owner connection: NSXPCConnection?,
              reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            guard let connection else { reply(false, "The helper could not tell who asked."); return }
            let uid = connection.effectiveUserIdentifier
            guard Self.isConsoleUser(uid) else {
                reply(false, "Only the person using this Mac's screen can send a Bluetooth device to a virtual machine.")
                return
            }
            if let problem = streamSocketProblem(streamSocketPath, uid: uid) {
                os_log("bluetooth hold refused: %{public}@", log: log, type: .error, problem)
                reply(false, "The connection to the virtual machine isn't ready (\(problem)).")
                return
            }
            guard self.held[id] == nil else { reply(false, "That device is already in a virtual machine."); return }
            let all = Self.allDevices()
            guard let device = Self.bluetoothDevices().first(where: { Self.identifier($0) == id }) else {
                reply(false, "That Bluetooth device isn't connected. Turn it on, or wake it, and try again.")
                return
            }
            if let reason = Self.mustStayOnMac(device, among: all.filter { !HeldByHelper.contains($0) }) {
                reply(false, reason)
                return
            }
            let socket = Self.connectSocket(streamSocketPath, owner: uid, peerPID: pid_t(clamping: peerPID))
            guard socket >= 0 else {
                reply(false, "The helper couldn't reach the virtual machine's socket.")
                return
            }
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            guard result == kIOReturnSuccess else {
                close(socket)
                os_log("couldn't take a Bluetooth device: 0x%{public}x", log: log, type: .error, result)
                reply(false, String(format: "macOS wouldn't let the helper take the device (error 0x%08x).", result))
                return
            }
            let size = max(64, min(4096, Self.property(device, kIOHIDMaxInputReportSizeKey) as? Int ?? 64))
            let descriptor = Self.property(device, kIOHIDReportDescriptorKey) as? Data ?? Data()
            let entry = Held(id: id, device: device, socket: socket, owner: connection, ownerUID: uid,
                             inputSize: size, usesReportIDs: Self.usesReportIDs(descriptor))
            self.held[id] = entry
            HeldByHelper.add(device)
            self.start(entry)
            self.watchWhileHeld()
            idle.bluetoothChanged(count: self.held.count)
            os_log("Bluetooth device held for a virtual machine", log: log, type: .default)
            reply(true, nil)
        }
    }

    func release(_ id: String, owner connection: NSXPCConnection?) {
        queue.async {
            guard let entry = self.held[id], entry.owner === connection || entry.owner == nil else { return }
            self.stop(entry, notify: false, detail: nil)
        }
    }

    /// Everything one AVM held, when its connection ends.
    func releaseAll(owner connection: NSXPCConnection?) {
        queue.async {
            for entry in self.held.values where entry.owner === connection || entry.owner == nil {
                self.stop(entry, notify: false, detail: nil)
            }
        }
    }

    // MARK: Relaying

    private func start(_ entry: Held) {
        let context = Unmanaged.passUnretained(entry).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(entry.device, entry.inputReport, entry.inputSize, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let entry = Unmanaged<Held>.fromOpaque(context).takeUnretainedValue()
            BluetoothHold.shared.forwardInput(entry, reportID: reportID, report: report, length: length)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(entry.device, { context, _, _ in
            guard let context else { return }
            let entry = Unmanaged<Held>.fromOpaque(context).takeUnretainedValue()
            BluetoothHold.shared.stop(entry, notify: true, detail: "it disconnected")
        }, context)
        IOHIDDeviceSetDispatchQueue(entry.device, queue)
        let device = entry.device
        // The entry lives until the last callback has run: the cancel
        // handler holds it, and the callbacks get it unretained.
        IOHIDDeviceSetCancelHandler(device) {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            _ = entry
        }
        IOHIDDeviceActivate(device)

        let source = DispatchSource.makeReadSource(fileDescriptor: entry.socket, queue: queue)
        source.setEventHandler { [weak self] in self?.readSocket(entry) }
        // The descriptor stays open until the source is done with it.
        let socket = entry.socket
        source.setCancelHandler { close(socket) }
        source.resume()
        entry.readSource = source
    }

    /// The report as the guest expects it: with its report ID first when
    /// the device uses IDs (macOS gives some reports without it).
    private func forwardInput(_ entry: Held, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard held[entry.id] === entry, length > 0 else { return }
        var bytes = Data(bytes: report, count: length)
        if entry.usesReportIDs, reportID != 0, bytes.first != UInt8(truncatingIfNeeded: reportID) {
            bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
        }
        guard writeFrame(entry, type: 1, bytes) else {
            stop(entry, notify: true, detail: "the virtual machine closed its side")
            return
        }
    }

    private func writeFrame(_ entry: Held, type: UInt8, _ payload: Data) -> Bool {
        guard payload.count <= 1024 else { return true }
        var frame = Data([type, UInt8(payload.count & 0xff), UInt8(payload.count >> 8)])
        frame.append(payload)
        // Without blocking (2026-10-28, security review): a machine not
        // draining its side (paused) held up every other Bluetooth device
        // and every hold and release behind it. A frame that can't start
        // is dropped, as a lost HID report is; one begun is finished,
        // waiting up to 2 seconds so the framing stays whole.
        return frame.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = send(entry.socket, raw.baseAddress! + offset, raw.count - offset, MSG_DONTWAIT)
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN {
                    if offset == 0 { return true }
                    var ready = pollfd(fd: entry.socket, events: Int16(POLLOUT), revents: 0)
                    guard poll(&ready, 1, 2000) > 0 else { return false }
                    continue
                }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    private func readSocket(_ entry: Held) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(entry.socket, &chunk, chunk.count)
        guard n > 0 else {
            stop(entry, notify: true, detail: "the virtual machine closed its side")
            return
        }
        entry.buffer.append(contentsOf: chunk[0..<n])
        while entry.buffer.count >= 3 {
            let start = entry.buffer.startIndex
            let type = entry.buffer[start]
            let length = Int(entry.buffer[start + 1]) | Int(entry.buffer[start + 2]) << 8
            guard length <= 1024 else { entry.buffer.removeAll(); return }
            guard entry.buffer.count >= 3 + length else { return }
            let payload = Data(entry.buffer[(start + 3)..<(start + 3 + length)])
            entry.buffer.removeFirst(3 + length)
            guard type == 2 || type == 3, !payload.isEmpty else { continue }
            let reportType = type == 3 ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput
            let reportID = entry.usesReportIDs ? CFIndex(payload[payload.startIndex]) : 0
            payload.withUnsafeBytes { raw in
                let result = IOHIDDeviceSetReport(entry.device, reportType, reportID,
                                                  raw.bindMemory(to: UInt8.self).baseAddress!, payload.count)
                if result != kIOReturnSuccess {
                    os_log("a report to the Bluetooth device failed: 0x%{public}x", log: log, type: .error, result)
                }
            }
        }
    }

    private func stop(_ entry: Held, notify: Bool, detail: String?) {
        guard held[entry.id] === entry else { return }
        held[entry.id] = nil
        HeldByHelper.remove(entry.device)
        if let source = entry.readSource {
            source.cancel()                  // closes the socket when done
        } else {
            close(entry.socket)
        }
        entry.readSource = nil
        IOHIDDeviceCancel(entry.device)     // closed in its cancel handler
        idle.bluetoothChanged(count: held.count)
        watchWhileHeld()
        os_log("Bluetooth device let go", log: log, type: .default)
        if notify {
            (entry.owner?.remoteObjectProxy as? AVMUSBHelperClientProtocol)?.bluetoothState(entry.id, held: false, detail: detail)
        }
    }

    // MARK: Rules

    /// The Mac's only keyboard or only pointing device stays on the Mac.
    private static func mustStayOnMac(_ device: IOHIDDevice, among all: [IOHIDDevice]) -> String? {
        func isKind(_ d: IOHIDDevice, _ usages: [Int]) -> Bool {
            (property(d, kIOHIDPrimaryUsagePageKey) as? Int) == kHIDPage_GenericDesktop
                && usages.contains(property(d, kIOHIDPrimaryUsageKey) as? Int ?? -1)
        }
        let id = identifier(device)
        let keyboards = [kHIDUsage_GD_Keyboard]
        let pointers = [kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer]
        if isKind(device, keyboards), !all.contains(where: { isKind($0, keyboards) && identifier($0) != id }) {
            return "That is the Mac's only keyboard, and the Mac must keep one."
        }
        if isKind(device, pointers), !all.contains(where: { isKind($0, pointers) && identifier($0) != id }) {
            return "That is the Mac's only pointing device, and the Mac must keep one."
        }
        return nil
    }

    /// True when the report descriptor has a Report ID item.
    static func usesReportIDs(_ descriptor: Data) -> Bool {
        var i = descriptor.startIndex
        while i < descriptor.endIndex {
            let prefix = descriptor[i]
            if prefix == 0xfe {
                guard i + 1 < descriptor.endIndex else { break }
                i += 3 + Int(descriptor[i + 1])
                continue
            }
            var size = Int(prefix & 3)
            if size == 3 { size = 4 }
            if prefix & 0xfc == 0x84 { return true }
            i += 1 + size
        }
        return false
    }

    /// Connected as root, so the peer is checked after connecting, as
    /// usbstream.c does (2026-10-28, code review): the path check can't
    /// see a symlink swapped in after it. A write to a stuck peer gives up
    /// after two seconds rather than blocking every Bluetooth device.
    private static func connectSocket(_ path: String, owner: uid_t, peerPID: pid_t) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return -1 }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == owner else {
            os_log("bluetooth hold refused: the socket's other side isn't the user who asked", log: log, type: .error)
            close(fd)
            return -1
        }
        // And QEMU itself (2026-10-28, security review): the same user's
        // other processes could listen at that path instead.
        var gotPID: pid_t = 0
        var pidLen = socklen_t(MemoryLayout<pid_t>.size)
        if peerPID > 0, getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &gotPID, &pidLen) != 0 || gotPID != peerPID {
            os_log("bluetooth hold refused: another process is listening on the machine's socket", log: log, type: .error)
            close(fd)
            return -1
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func isConsoleUser(_ uid: uid_t) -> Bool {
        var consoleUID: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) != nil else { return false }
        return consoleUID == uid
    }
}
