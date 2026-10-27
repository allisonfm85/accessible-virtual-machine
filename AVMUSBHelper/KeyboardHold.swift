// KeyboardHold.swift
// AVMUSBHelper — AVM's privileged helper
//
// A keyboard for Windows (2026-10-26). A second keyboard, USB or
// Bluetooth, chosen in AVM's Settings, types only into Windows: the
// helper opens it with kIOHIDOptionsTypeSeizeDevice, which takes it away
// from macOS (and so from VoiceOver) entirely, and passes each key to the
// AVM that asked. macOS allows seizing a keyboard only to a privileged
// process (measured: kIOReturnNotPrivileged as a user), which is why this
// lives in the helper rather than the app.
//
// The rules, each because a keyboard carries everything a person types:
//   - Keys go to the one connection that asked, and nowhere else; the
//     helper never logs a key, only that a keyboard was held or let go.
//   - Only for the user at the Mac's screen (the console user), so one
//     user's AVM can't take another user's keyboard.
//   - Never the built-in keyboard, and never the only keyboard: the Mac
//     must always keep one.
//   - Let go when AVM asks, when its connection ends (quit or crash), or
//     when the keyboard disconnects; while wanted and not connected, the
//     helper looks for it every few seconds, so a Bluetooth keyboard that
//     wakes up later is taken then.
// The helper reads only page-7 (keyboard) key usages; it never opens any
// other keyboard, so it can't see what is typed on the Mac's own.

import Foundation
import IOKit.hid
import SystemConfiguration
import os.log

final class KeyboardHold {
    static let shared = KeyboardHold()

    let queue = DispatchQueue(label: "keyboard-hold")
    private var wantedID: String?
    private weak var owner: NSXPCConnection?
    private var held: IOHIDDevice?
    private var heldID: String?
    private var lookTimer: DispatchSourceTimer?

    var isActive: Bool { queue.sync { wantedID != nil } }

    // MARK: Finding keyboards

    private static func keyboards() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: NSDictionary = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                                   kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard]
        IOHIDManagerSetDeviceMatching(manager, match)
        return Array(IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [])
    }

    private static func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as NSString)
    }

    /// Stable across reconnects: vendor, product and serial number (a
    /// Bluetooth keyboard's serial is its address); the location for a
    /// keyboard with no serial.
    static func identifier(_ device: IOHIDDevice) -> String {
        let vendor = property(device, kIOHIDVendorIDKey) as? Int ?? 0
        let product = property(device, kIOHIDProductIDKey) as? Int ?? 0
        let serial = (property(device, kIOHIDSerialNumberKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "loc\(property(device, kIOHIDLocationIDKey) as? Int ?? 0)"
        return String(format: "%04x:%04x:", vendor, product) + serial
    }

    private static func isBuiltIn(_ device: IOHIDDevice) -> Bool {
        (property(device, "Built-In") as? Bool) == true
            || (property(device, kIOHIDTransportKey) as? String) == "FIFO"
    }

    func list() -> [NSDictionary] {
        Self.keyboards().map { device in
            [
                "id": Self.identifier(device),
                "name": Self.property(device, kIOHIDProductKey) as? String ?? "Keyboard",
                "transport": Self.property(device, kIOHIDTransportKey) as? String ?? "",
                "builtIn": NSNumber(value: Self.isBuiltIn(device)),
            ] as NSDictionary
        }
    }

    // MARK: Holding

    func hold(_ keyboardID: String, owner connection: NSXPCConnection?, reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            guard let connection else { reply(false, "The helper could not tell who asked."); return }
            guard Self.isConsoleUser(connection.effectiveUserIdentifier) else {
                reply(false, "Only the person using this Mac's screen can choose a keyboard for Windows.")
                return
            }
            if let other = self.owner, other !== connection, self.wantedID != nil {
                _ = other
                reply(false, "Another copy of AVM is using a keyboard for Windows.")
                return
            }
            self.releaseHeld(notify: false)
            self.wantedID = keyboardID
            self.owner = connection
            idle.keyboardChanged(held: true)
            reply(true, nil)
            os_log("keyboard for Windows requested", log: log, type: .default)
            self.lookForKeyboard()
        }
    }

    func release(owner connection: NSXPCConnection?) {
        queue.async {
            guard self.owner === connection || self.owner == nil else { return }
            self.stopLooking()
            self.releaseHeld(notify: false)
            self.wantedID = nil
            self.owner = nil
            idle.keyboardChanged(held: false)
        }
    }

    private func lookForKeyboard() {
        guard let wanted = wantedID, held == nil else { return }
        let all = Self.keyboards()
        guard let device = all.first(where: { Self.identifier($0) == wanted }) else {
            startLooking()
            return
        }
        if Self.isBuiltIn(device) {
            refuse(wanted, "AVM never takes the Mac's built-in keyboard.")
            return
        }
        if all.count < 2 {
            refuse(wanted, "That is the only keyboard connected, and the Mac must keep one. Connect another keyboard for the Mac, then start again.")
            return
        }
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard opened == kIOReturnSuccess else {
            os_log("couldn't hold the keyboard for Windows: 0x%{public}x", log: log, type: .error, opened)
            refuse(wanted, String(format: "macOS wouldn't let the helper take the keyboard (error 0x%08x).", opened))
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<KeyboardHold>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<KeyboardHold>.fromOpaque(context).takeUnretainedValue().keyboardWentAway()
        }, context)
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceActivate(device)
        held = device
        heldID = wanted
        stopLooking()
        os_log("keyboard for Windows held", log: log, type: .default)
        client()?.keyboardState(wanted, held: true, detail: Self.property(device, kIOHIDProductKey) as? String)
    }

    /// On `queue`. Only page-7 key usages, 4 through 0xE7; the rest
    /// (rollover reports, vendor pages) are dropped. Never logged.
    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
        let usage = Int(IOHIDElementGetUsage(element))
        guard (0x04...0xE7).contains(usage) else { return }
        client()?.keyboardKey(usage: usage, pressed: IOHIDValueGetIntegerValue(value) != 0)
    }

    private func keyboardWentAway() {
        guard let id = heldID else { return }
        os_log("keyboard for Windows disconnected", log: log, type: .default)
        releaseHeld(notify: false)
        client()?.keyboardState(id, held: false, detail: "disconnected")
        lookForKeyboard()
    }

    private func refuse(_ id: String, _ reason: String) {
        client()?.keyboardState(id, held: false, detail: reason)
        stopLooking()
        wantedID = nil
        idle.keyboardChanged(held: false)
    }

    private func releaseHeld(notify: Bool) {
        guard let device = held else { return }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        IOHIDDeviceSetCancelHandler(device) {}
        IOHIDDeviceCancel(device)
        held = nil
        if notify, let id = heldID { client()?.keyboardState(id, held: false, detail: nil) }
        heldID = nil
        os_log("keyboard for Windows released", log: log, type: .default)
    }

    private func startLooking() {
        guard lookTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.lookForKeyboard() }
        timer.resume()
        lookTimer = timer
    }

    private func stopLooking() {
        lookTimer?.cancel()
        lookTimer = nil
    }

    private func client() -> AVMUSBHelperClientProtocol? {
        owner?.remoteObjectProxy as? AVMUSBHelperClientProtocol
    }

    private static func isConsoleUser(_ uid: uid_t) -> Bool {
        var consoleUID: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) != nil else { return false }
        return consoleUID == uid
    }
}
