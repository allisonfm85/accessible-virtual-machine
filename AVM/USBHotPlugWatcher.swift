//
//  USBHotPlugWatcher.swift
//  AVM
//
//  USB increment 2b, piece 3: notices USB devices arriving and leaving
//  while a VM runs, and acts on each arrival's decision (piece 4):
//  "ask" goes to USBPlugPrompt's alert, "send to Windows" (Always mode
//  or a remembered choice) goes straight to USBPlugPrompt.send, and a
//  remembered "keep on the Mac" is silent by design (Allison,
//  2026-10-12). Removals go to USBPlugPrompt too.
//
//  How it works: IOKit tells AVM about every IOUSBHostDevice that
//  appears (first-match notification) or goes away (terminated
//  notification). Both arrive on the main run loop.
//
//  Rules this file keeps:
//  - It reads the SAVED configuration from VMStore.shared at every
//    arrival, never a copy taken at VM start, so USB changes made in
//    Settings apply right away.
//  - Arming a notification also reports every device already present.
//    Those are recorded quietly, not treated as plugged in, so the
//    keyboard in use is never "new". Recording them means a later
//    removal of one of them is still noticed.
//  - A removal can arrive after the device's properties are gone, so
//    the identity recorded at arrival is looked up by registry entry ID.
//  - Interfaces are often published a moment after the device itself,
//    so class codes are read after a short delay.
//  - The log says whether a device has a serial number, never the
//    serial itself. Diagnostic logs get attached to public issues.
//
//  VMManager starts the watcher when the VM reaches running and stops
//  it at stopped or error. While paused it keeps listening. Attaching
//  refuses while paused, and piece 4 decides what to say then.
//

import Foundation
import IOKit

final class USBHotPlugWatcher {
    static let shared = USBHotPlugWatcher()

    /// The VM being watched for, or nil when not watching.
    private(set) var vmID: UUID?

    private var notifyPort: IONotificationPortRef?
    private var arrivedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    /// Every device seen since start, by registry entry ID.
    private var known: [UInt64: AVMUSBDeviceIdentity] = [:]

    /// How long to wait after an arrival before reading class codes.
    private static let classReadDelay: Duration = .seconds(1)

    private init() {}

    // MARK: Start and stop

    func start(vmID: UUID) {
        if self.vmID == vmID { return }
        if self.vmID != nil { stop(reason: "switching to another VM") }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            log("start: IONotificationPortCreate returned nil; not watching")
            return
        }
        notifyPort = port
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let arrivedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<USBHotPlugWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.handleArrivals(iterator) }
        }
        let removedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<USBHotPlugWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.handleRemovals(iterator) }
        }

        var kr = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                                  IOServiceMatching("IOUSBHostDevice"),
                                                  arrivedCallback, refcon, &arrivedIterator)
        guard kr == KERN_SUCCESS else {
            log("start: arrival notification failed: \(kr); not watching")
            stop(reason: "arrival notification failed")
            return
        }
        kr = IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                              IOServiceMatching("IOUSBHostDevice"),
                                              removedCallback, refcon, &removedIterator)
        guard kr == KERN_SUCCESS else {
            log("start: removal notification failed: \(kr); not watching")
            stop(reason: "removal notification failed")
            return
        }

        self.vmID = vmID
        known = [:]
        // Draining both iterators arms them. Devices already present
        // are recorded, not announced.
        let present = recordPresent(arrivedIterator)
        forEach(removedIterator) { _ in }
        log("start: watching USB for VM \(vmID.uuidString); \(present) \(present == 1 ? "device" : "devices") already present, recorded quietly")
    }

    func stop(reason: String) {
        guard vmID != nil || notifyPort != nil else { return }
        USBPlugPrompt.shared.vmStopped()
        if arrivedIterator != 0 { IOObjectRelease(arrivedIterator); arrivedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port = notifyPort { IONotificationPortDestroy(port); notifyPort = nil }
        log("stop: \(reason); no longer watching USB")
        vmID = nil
        known = [:]
    }

    // MARK: Arrivals and removals

    private func handleArrivals(_ iterator: io_iterator_t) {
        forEach(iterator) { service in
            guard let entryID = registryID(service) else {
                log("arrived: a device with no registry entry ID; skipped")
                return
            }
            guard let identity = USBDeviceEnumerator.identity(for: service) else {
                log("arrived: registry entry \(entryID) has no vendor, product, location, or address; skipped")
                return
            }
            known[entryID] = identity
            IOObjectRetain(service)
            let vmAtArrival = vmID
            Task { @MainActor in
                try? await Task.sleep(for: USBHotPlugWatcher.classReadDelay)
                defer { IOObjectRelease(service) }
                guard vmAtArrival != nil, self.vmID == vmAtArrival else {
                    self.log("arrived: \(identity), but watching stopped before its class codes were read")
                    return
                }
                self.logArrival(identity, entryID: entryID, service: service)
            }
        }
    }

    private func handleRemovals(_ iterator: io_iterator_t) {
        forEach(iterator) { service in
            guard let entryID = registryID(service) else {
                log("removed: a device with no registry entry ID")
                return
            }
            if let identity = known.removeValue(forKey: entryID) {
                log("removed: \(identity)")
                // The watcher is the final word on whether a device is
                // here. If it was in Windows and the helper stays silent,
                // the controller cleans up (2026-10-17).
                USBRedirectController.shared.deviceVanished(identity)
            } else {
                log("removed: registry entry \(entryID), never seen arriving")
            }
            USBPlugPrompt.shared.removed(entryID: entryID)
        }
    }

    private func logArrival(_ identity: AVMUSBDeviceIdentity, entryID: UInt64, service: io_service_t) {
        // A device already in Windows has nothing to decide. Evidence
        // (2026-10-12): attaching did not make macOS drop and re-add the
        // device, so this is a safety net, not a known path.
        if USBRedirectController.shared.portByDevice.keys.contains(where: {
            $0.vendorID == identity.vendorID && $0.productID == identity.productID
                && $0.busNumber == identity.busNumber && $0.deviceAddress == identity.deviceAddress
        }) {
            log("arrived: \(identity) is already in Windows; nothing to decide")
            return
        }
        // Coming home after AVM's own Detach. macOS can drop and re-add
        // the device several times on the way (log, 2026-10-12).
        if USBRedirectController.shared.isBeingHandedBack(identity) {
            log("arrived: \(identity) is being handed back to the Mac by AVM; nothing to decide")
            return
        }
        let classes = USBDeviceEnumerator.classCodes(for: service)
        let deviceClass = classes.device.map { String(format: "0x%02x", $0) } ?? "none"
        let interfaceList = classes.interfaces.isEmpty
            ? "none yet"
            : classes.interfaces.map { String(format: "0x%02x", $0) }.joined(separator: ",")
        let serial = identity.serialNumber == nil ? "no" : "yes"
        let classification = USBDeviceClassifier.classify(service, identity: identity)
        let decided = decide(for: identity, classification: classification)
        log("arrived: \(identity), serial \(serial), device class \(deviceClass), interface classes \(interfaceList); \(classification.logText); decision: \(decided.text)")
        guard let vmID, let decision = decided.decision else { return }
        var rememberOffered = false
        if case .ask(let offered) = decision { rememberOffered = offered }
        let question = USBPlugQuestion(entryID: entryID,
                                       vmID: vmID,
                                       identity: identity,
                                       vendorName: vendorName(service),
                                       kind: classification.kind,
                                       rememberOffered: rememberOffered)
        // Follow-through (Allison, 2026-10-17): the same device left
        // Windows moments ago, as a Monarch does when it switches modes,
        // so it follows the user's choice back. Never for always-ask
        // devices. The check also clears the vanished copy quietly.
        if classification.protection != .alwaysAsk,
           USBRedirectController.shared.takeFollowThrough(identity) {
            log("arrived: \(identity) left Windows moments ago; following the user's choice back to Windows")
            USBPlugPrompt.shared.send(question, because: "came back within \(Int(USBRedirectController.followWindow)) seconds of leaving Windows")
            return
        }
        switch decision {
        case .ask:
            USBPlugPrompt.shared.ask(question)
        case .sendToWindows:
            USBPlugPrompt.shared.send(question, because: decided.text)
        case .keepOnMac:
            // Silent by design: the device simply works on the Mac.
            break
        }
    }

    /// What AVM would do with this device: the SAVED settings, read fresh
    /// from VMStore at the moment of arrival, plus the classifier's answer,
    /// run through USBPlugDecider. logArrival acts on the answer.
    /// When the settings can't be read, the answer is ask, the safe one,
    /// with no Remember option, since there is nowhere to save it.
    private func decide(for identity: AVMUSBDeviceIdentity,
                        classification: USBDeviceClassification) -> (decision: USBPlugDecision?, text: String) {
        guard let vmID else { return (nil, "none (not watching)") }
        guard let store = VMStore.shared,
              let config = store.configurations.first(where: { $0.id == vmID }) else {
            return (.ask(rememberOffered: false),
                    "ask (no remember option): saved settings for VM \(vmID.uuidString) are not available")
        }
        let remembered = config.usbRememberedDevices?.first(where: {
            $0.matches(vendorID: Int(identity.vendorID),
                       productID: Int(identity.productID),
                       serialNumber: identity.serialNumber)
        })
        let note = (remembered != nil && remembered?.usesWindows == nil)
            ? "; remembered word '\(remembered?.decision ?? "")' not understood, ignored"
            : ""
        let result = USBPlugDecider.decide(mode: config.effectiveUSBMode,
                                           remembered: remembered?.usesWindows,
                                           protection: classification.protection)
        return (result.decision, "\(result.decision.logText) (\(result.why))\(note)")
    }

    // MARK: Helpers

    private func recordPresent(_ iterator: io_iterator_t) -> Int {
        var count = 0
        forEach(iterator) { service in
            guard let entryID = registryID(service),
                  let identity = USBDeviceEnumerator.identity(for: service) else { return }
            known[entryID] = identity
            count += 1
        }
        return count
    }

    /// Calls body for each service in the iterator, releasing each one
    /// after body returns. Emptying the iterator is what arms it.
    private func forEach(_ iterator: io_iterator_t, _ body: (io_service_t) -> Void) {
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            body(service)
            IOObjectRelease(service)
        }
    }

    /// The maker's name the device reports, for the alert. Read here
    /// rather than added to AVMUSBDeviceIdentity, which the privileged
    /// helper shares.
    private func vendorName(_ service: io_service_t) -> String? {
        IORegistryEntryCreateCFProperty(service, "USB Vendor Name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private func registryID(_ service: io_service_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : nil
    }

    private func log(_ message: String) {
        AVMLog.write("USBHotPlugWatcher: \(message)", category: "USBHotPlug")
    }
}
