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
//     must always keep one. While the Mac has no other (at login, its own
//     Bluetooth keyboard connects a few seconds later), the helper waits
//     and takes the keyboard once it does; while held, the other going
//     away for more than a few seconds gives the keyboard back until the
//     Mac has another again (2026-10-28).
//   - Never a braille display with a keyboard (2026-10-29): seized, it's
//     gone from VoiceOver. It goes to a machine as itself instead.
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

/// The devices this helper holds right now, by IOKit registry entry
/// (2026-10-28, code review). macOS still lists a seized device, so each
/// hold counted the other's keyboard as one the Mac could type with: the
/// keyboard for Windows and a Bluetooth keyboard sent to a machine could
/// between them leave the Mac with none. Both rules now leave these out.
enum HeldByHelper {
    private static let lock = NSLock()
    private static var entries = Set<UInt64>()
    /// Taken by both holds across "count the Mac's other keyboards, open,
    /// add" (2026-10-29, sixth audit): each could count before the other's
    /// add, and between them take the Mac's last two keyboards at once.
    /// Never held while AVM is told anything.
    static let taking = NSLock()

    static func entryID(_ device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : nil
    }
    static func add(_ device: IOHIDDevice) {
        guard let id = entryID(device) else { return }
        lock.lock(); entries.insert(id); lock.unlock()
    }
    static func remove(_ device: IOHIDDevice) {
        guard let id = entryID(device) else { return }
        lock.lock(); entries.remove(id); lock.unlock()
    }
    static func contains(_ device: IOHIDDevice) -> Bool {
        guard let id = entryID(device) else { return false }
        lock.lock(); defer { lock.unlock() }
        return entries.contains(id)
    }
}

final class KeyboardHold {
    static let shared = KeyboardHold()

    let queue = DispatchQueue(label: "keyboard-hold")
    private var wantedID: String?
    private weak var owner: NSXPCConnection?
    /// Every interface of the chosen keyboard (2026-10-26, keyboard
    /// audit): many keyboards show macOS two or more (a boot keyboard and an
    /// n-key-rollover one, or a receiver's several), and holding only one
    /// left the others typing on the Mac.
    private var held: [IOHIDDevice] = []
    private var heldID: String?
    private var heldOwnerUID: uid_t?
    private var lookTimer: DispatchSourceTimer?
    /// While held: checks every few seconds that the Mac still has another
    /// keyboard and that the person who asked is still at the screen.
    private var watchTimer: DispatchSourceTimer?
    /// Checks in a row that found the Mac without another keyboard
    /// (2026-10-28): the keyboard is given back after two, 6 seconds, so a
    /// Bluetooth keyboard's moment away doesn't cost it.
    private var checksWithoutAnother = 0
    /// AVM has been told, once, that the helper is waiting for the Mac to
    /// have another keyboard.
    private var saidWaiting = false
    /// Opens refused as exclusive and looked for again (fifth audit).
    private var exclusiveRetries = 0

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

    /// Keyboards the Mac could still type with if `wanted` were held:
    /// distinct keyboards other than it, not counting security keys and
    /// virtual keyboards, which show macOS a keyboard but aren't one a
    /// person can type with (2026-10-26, keyboard audit: one keyboard plus
    /// a YubiKey passed the old "two keyboards" count).
    private static func otherKeyboards(_ all: [IOHIDDevice], than wanted: String) -> Int {
        let ids = all.filter { device in
            if HeldByHelper.contains(device) { return false }   // in a machine already
            let vendor = property(device, kIOHIDVendorIDKey) as? Int ?? 0
            let transport = (property(device, kIOHIDTransportKey) as? String ?? "").lowercased()
            // A keyboard first and foremost (2026-10-28, fifth audit): the
            // match in keyboards() takes any device with a keyboard
            // collection, so a gaming mouse or a barcode scanner counted,
            // and the Mac's only typing keyboard could be taken.
            let primaryPage = property(device, kIOHIDPrimaryUsagePageKey) as? Int ?? 0
            let primaryUsage = property(device, kIOHIDPrimaryUsageKey) as? Int ?? 0
            return identifier(device) != wanted
                && primaryPage == kHIDPage_GenericDesktop && primaryUsage == kHIDUsage_GD_Keyboard
                && vendor != 0x1050                 // Yubico
                && transport != "virtual"
                && !(property(device, kIOHIDProductKey) as? String ?? "").lowercased().contains("karabiner")
        }.map(identifier)
        return Set(ids).count
    }

    private static func isBuiltIn(_ device: IOHIDDevice) -> Bool {
        (property(device, "Built-In") as? Bool) == true
            || (property(device, kIOHIDTransportKey) as? String) == "FIFO"
    }

    /// A braille display: usage page 0x41 among the interface's top-level
    /// collections, beside the keyboard one that put it in keyboards().
    private static func isBraille(_ device: IOHIDDevice) -> Bool {
        let pairs = property(device, kIOHIDDeviceUsagePairsKey) as? [[String: Any]] ?? []
        return pairs.contains { ($0[kIOHIDDeviceUsagePageKey] as? Int) == 0x41 }
    }

    /// One row per keyboard, not per interface (2026-10-29, sixth audit):
    /// a keyboard with a boot and an n-key-rollover interface was listed,
    /// and read by VoiceOver, twice under one id. Built in if any of its
    /// interfaces is. A braille display isn't listed: it's never taken.
    func list() -> [NSDictionary] {
        let all = Self.keyboards()
        var seen = Set<String>()
        return all.compactMap { device -> NSDictionary? in
            let id = Self.identifier(device)
            guard seen.insert(id).inserted else { return nil }
            let interfaces = all.filter { Self.identifier($0) == id }
            if interfaces.contains(where: Self.isBraille) { return nil }
            return [
                "id": id,
                "name": Self.property(device, kIOHIDProductKey) as? String ?? "Keyboard",
                "transport": Self.property(device, kIOHIDTransportKey) as? String ?? "",
                "builtIn": NSNumber(value: interfaces.contains(where: Self.isBuiltIn)),
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
            self.heldOwnerUID = connection.effectiveUserIdentifier
            self.saidWaiting = false
            // Not a count left by tries for the last hold (2026-10-29,
            // sixth audit): it was reset only on success or refusal.
            self.exclusiveRetries = 0
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
            self.heldOwnerUID = nil
            self.exclusiveRetries = 0
            idle.keyboardChanged(held: false)
        }
    }

    private func lookForKeyboard() {
        guard let wanted = wantedID, held.isEmpty else { return }
        if let uid = heldOwnerUID, !Self.isConsoleUser(uid) {
            startLooking()                    // their turn at the screen again later
            return
        }
        let all = Self.keyboards()
        let interfaces = all.filter { Self.identifier($0) == wanted }
        guard let first = interfaces.first else {
            startLooking()
            return
        }
        if interfaces.contains(where: Self.isBuiltIn) {
            refuse(wanted, "AVM never takes the Mac's built-in keyboard.")
            return
        }
        // A braille display with a keyboard (2026-10-29, sixth audit): seized
        // whole, it was gone from VoiceOver for as long as the machine ran,
        // its cells and keys reaching neither the Mac nor Windows.
        if interfaces.contains(where: Self.isBraille) {
            refuse(wanted, "it's a braille display; send it to a machine with Bluetooth Devices or Attach USB Device instead.")
            return
        }
        // The count, the open and the add under the lock the Bluetooth hold
        // takes too (2026-10-29, sixth audit), so the two can't both find
        // the Mac another keyboard at once. Unlocked on every way out,
        // before AVM is told anything.
        HeldByHelper.taking.lock()
        // In a machine through Bluetooth Devices (2026-10-29, sixth audit):
        // the helper's own Bluetooth hold has it, and the open was tried
        // for 15 seconds, then blamed on another app.
        if interfaces.contains(where: HeldByHelper.contains) {
            HeldByHelper.taking.unlock()
            refuse(wanted, "it's in a virtual machine already, sent there from Bluetooth Devices.")
            return
        }
        // The only keyboard: not a refusal (2026-10-28, a user's report). At
        // login the Mac's own Bluetooth keyboard connects seconds after AVM
        // asks, so the helper waits and takes this one once the Mac has
        // another; AVM is told once, as "waiting".
        if Self.otherKeyboards(all, than: wanted) < 1 {
            HeldByHelper.taking.unlock()
            if !saidWaiting {
                saidWaiting = true
                os_log("keyboard for Windows: waiting for the Mac to have another keyboard", log: log, type: .default)
                client()?.keyboardState(wanted, held: false, detail: "waiting")
            }
            startLooking()
            return
        }
        var opened: [IOHIDDevice] = []
        for device in interfaces {
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            guard result == kIOReturnSuccess else {
                os_log("couldn't hold the keyboard for Windows: 0x%{public}x", log: log, type: .error, result)
                for done in opened { IOHIDDeviceClose(done, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) }
                HeldByHelper.taking.unlock()
                // Held exclusively by someone (2026-10-28, fifth audit): most
                // often the helper's own last hold, closing in a cancel
                // handler queued behind this block (a hand-over between
                // machines releases and holds back to back). Looked for
                // again, a few times, before it's a refusal.
                let exclusive = IOReturn(bitPattern: 0xe00002c5)
                if result == exclusive, exclusiveRetries < 5 {
                    exclusiveRetries += 1
                    // The first time on the queue's next turn, after those
                    // cancel handlers (2026-10-29, sixth audit): 3 seconds
                    // left the keyboard typing into the Mac's front app
                    // meanwhile. The 3-second look is the fallback.
                    if exclusiveRetries == 1 {
                        queue.async { [weak self] in self?.lookForKeyboard() }
                    } else {
                        startLooking()
                    }
                    return
                }
                exclusiveRetries = 0
                refuse(wanted, result == exclusive
                       ? "another app has taken the keyboard."
                       : String(format: "macOS wouldn't let the helper take the keyboard (error 0x%08x).", result))
                return
            }
            opened.append(device)
        }
        for device in opened { HeldByHelper.add(device) }
        HeldByHelper.taking.unlock()
        let context = Unmanaged.passUnretained(self).toOpaque()
        for device in opened {
            IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
                guard let context else { return }
                Unmanaged<KeyboardHold>.fromOpaque(context).takeUnretainedValue().handle(value)
            }, context)
            IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
                guard let context else { return }
                Unmanaged<KeyboardHold>.fromOpaque(context).takeUnretainedValue().keyboardWentAway()
            }, context)
            IOHIDDeviceSetDispatchQueue(device, queue)
            // As IOHIDDevice.h has it: the cancel handler set before
            // activating, and the device let go (closed, and its last
            // reference dropped, the closure's) only once it has run, after
            // the last callback.
            IOHIDDeviceSetCancelHandler(device) {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            }
            IOHIDDeviceActivate(device)
        }
        held = opened
        exclusiveRetries = 0
        heldID = wanted
        saidWaiting = false
        checksWithoutAnother = 0
        stopLooking()
        startWatching()
        os_log("keyboard for Windows held (%d interfaces)", log: log, type: .default, opened.count)
        client()?.keyboardState(wanted, held: true, detail: Self.property(first, kIOHIDProductKey) as? String)
    }

    /// While held: the Mac must still have a keyboard of its own, and the
    /// keyboard is only for the person at the screen (a fast user switch
    /// hands it back).
    private func startWatching() {
        guard watchTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.checkWhileHeld() }
        timer.resume()
        watchTimer = timer
    }

    private func checkWhileHeld() {
        guard let id = heldID, !held.isEmpty else { return }
        if let uid = heldOwnerUID, !Self.isConsoleUser(uid) {
            os_log("keyboard for Windows given back: its user left the screen", log: log, type: .default)
            releaseHeld(notify: false)
            client()?.keyboardState(id, held: false, detail: "away")
            startLooking()
            return
        }
        // The Mac's other keyboard gone for two checks in a row: this one
        // goes back to the Mac, which must keep one, and the helper keeps
        // looking, taking it again once the Mac has another (2026-10-28; it
        // used to be final, and a Bluetooth keyboard's moment away ended
        // the keyboard for Windows until the machine restarted).
        if Self.otherKeyboards(Self.keyboards(), than: id) < 1 {
            checksWithoutAnother += 1
            guard checksWithoutAnother >= 2 else { return }
            os_log("keyboard for Windows given back: the Mac had no other keyboard", log: log, type: .default)
            releaseHeld(notify: false)
            saidWaiting = true
            client()?.keyboardState(id, held: false, detail: "waiting")
            startLooking()
        } else {
            checksWithoutAnother = 0
        }
    }

    /// On `queue`. Only page-7 key usages, 4 through 0xE7, and an Apple
    /// keyboard's Fn; the rest (rollover reports, other vendor usages) are
    /// dropped. Never logged.
    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = Int(IOHIDElementGetUsage(element))
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        // An Apple keyboard's Fn key (2026-10-26): on Apple's own pages
        // (0xFF, the older top-case page, and 0xFF01), usage 3. macOS
        // turns Fn combinations into Forward Delete, Home, End and the
        // rest; with the keyboard held, AVM does (WindowsKeyboard), so Fn
        // goes to AVM as HIDKeyMap.fnUsage.
        if (page == 0xFF || page == 0xFF01) && usage == 0x03 {
            client()?.keyboardKey(usage: 0x1_0003, pressed: pressed)
            return
        }
        guard page == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
        guard (0x04...0xE7).contains(usage) else { return }
        client()?.keyboardKey(usage: usage, pressed: pressed)
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
        watchTimer?.cancel()
        watchTimer = nil
        guard !held.isEmpty else { return }
        for device in held {
            HeldByHelper.remove(device)
            IOHIDDeviceCancel(device)   // closed in its cancel handler
        }
        held = []
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
