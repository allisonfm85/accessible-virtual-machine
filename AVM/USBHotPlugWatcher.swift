//
//  USBHotPlugWatcher.swift
//  AVM
//
//  USB increment 2b, piece 3: notices USB devices arriving and leaving
//  while a VM runs. Detection only. Piece 4 adds the alert, the spoken
//  line while in Windows, and attaching.
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
                self.logArrival(identity, service: service)
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
            } else {
                log("removed: registry entry \(entryID), never seen arriving")
            }
        }
    }

    private func logArrival(_ identity: AVMUSBDeviceIdentity, service: io_service_t) {
        let classes = USBDeviceEnumerator.classCodes(for: service)
        let deviceClass = classes.device.map { String(format: "0x%02x", $0) } ?? "none"
        let interfaceList = classes.interfaces.isEmpty
            ? "none yet"
            : classes.interfaces.map { String(format: "0x%02x", $0) }.joined(separator: ",")
        let serial = identity.serialNumber == nil ? "no" : "yes"
        let classification = USBDeviceClassifier.classify(service, identity: identity)
        log("arrived: \(identity), serial \(serial), device class \(deviceClass), interface classes \(interfaceList); settings say \(settingsSay(for: identity)); \(classification.logText)")
    }

    /// What the saved settings say to do with this device, read fresh
    /// from VMStore at the moment of arrival.
    private func settingsSay(for identity: AVMUSBDeviceIdentity) -> String {
        guard let vmID else { return "nothing (not watching)" }
        guard let store = VMStore.shared else { return "unknown (VMStore is not available)" }
        guard let config = store.configurations.first(where: { $0.id == vmID }) else {
            return "unknown (VM \(vmID.uuidString) has no saved configuration)"
        }
        if let remembered = config.usbRememberedDevices?.first(where: {
            $0.matches(vendorID: Int(identity.vendorID),
                       productID: Int(identity.productID),
                       serialNumber: identity.serialNumber)
        }) {
            switch remembered.usesWindows {
            case true?: return "remembered, use in Windows"
            case false?: return "remembered, keep on the Mac"
            case nil: return "remembered with unknown word '\(remembered.decision)', so ask"
            }
        }
        return "mode \(config.effectiveUSBMode.rawValue)"
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

    private func registryID(_ service: io_service_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : nil
    }

    private func log(_ message: String) {
        AVMLog.write("USBHotPlugWatcher: \(message)", category: "USBHotPlug")
    }
}
