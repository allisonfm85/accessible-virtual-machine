// USBManager.swift
// AVM — Accessible Virtual Machine
//
// ============================ DORMANT CODE ============================
// THIS CLASS IS NEVER INSTANTIATED. Grep-verified 2026-08-03 (same audit
// method as KeyboardInterceptor, Handoff 18 §1, and the orphaned cleanup()
// methods, 2026-07-26): outside this file, the only references to USBManager
// anywhere in the project are two comments noting that its cleanup() has no
// callers. No USBManager() construction, no @StateObject, no environment
// injection exists. ZERO code in this file executes — no notification port
// is created, no device is ever enumerated, and the print() lines are dead
// letters (left as-is deliberately; logging in code that never runs is
// dispositioned when the code becomes live).
//
// WHAT IS REAL AND WHAT IS NOT, so no reader mistakes the shape for the
// substance (the handleQMPLine rule — do not mistake this for running code):
//   - The IOKit half (enumeration, add/remove notifications, device
//     identity) is genuine host-side scaffolding and plausibly reusable.
//   - The VM half DOES NOT EXIST. attachToVM/detachFromVM flip a Bool and
//     print; nothing is wired to QEMU, usbredir, or any redirection
//     mechanism. If this class were ever instantiated as-is, "Attach to VM"
//     would claim an affordance it does not honor — the exact violation the
//     2026-07-19 honest-elements pass eliminated from the dashboard. Do not
//     wire this class to UI before the VM half exists.
//
// RETAINED DELIBERATELY — USB PASSTHROUGH IS THE NEXT FEATURE (decision of
// record 2026-08-03): first priority after the tester build ships, ahead of
// the ISO assistant and merged-or-adjacent with the audio latency
// investigation. Motivation: blind musicians need their equipment in the
// guest — audio interfaces and MIDI controllers reaching Windows audio
// software (the REAPER/OSARA ecosystem is Windows-first). For that user
// group this is the difference between AVM being useful and not. The tester
// docs announce it as next-up (no dates, no device promises — the Handoff 18
// §1 rule: intent must not read as fact) and invite testers to name the
// hardware they would connect; that list drives the testing targets.
//
// THE FEATURE PASS STARTS WITH A RESEARCH READ, NOT WITH THIS CODE
// (research-first, per the audio-latency precedent). Open questions:
//   1. Does our QEMU build include libusb / host USB passthrough support?
//      Check the sysroot before any Swift work.
//   2. Isochronous transfer quality — audio and MIDI class devices are the
//      HARD case (real-time delivery guarantees), historically the weakest
//      area of both QEMU passthrough and usbredir. Mass storage is the easy
//      case and is NOT the target.
//   3. usbredir (SPICE's redirection channel — we are already on SPICE)
//      versus QEMU-native passthrough: which path, and what does CocoaSpice
//      (currently imported as CocoaSpiceNoUsb) offer or preclude?
//   4. Host-side device claiming: capturing a device away from macOS varies
//      by device class; HID-adjacent devices are the awkward case.
//   5. End-to-end latency: host USB stack -> redirection -> guest driver,
//      stacked on the SPICE audio path — shared ground with the open audio
//      latency investigation; research them together. A musician cares
//      about the round trip, not just enumeration.
//   6. A hardware test with a real audio interface belongs in the research
//      pass, before design.
// Once those are answered, this code may be REWRITTEN rather than wired up
// — it predates every one of those questions.
// ======================================================================

import Foundation
import Combine
import IOKit
import IOKit.usb

/// Represents a USB device connected to the Mac.
struct USBDevice: Identifiable {
    let id: UUID
    let name: String
    let vendorID: Int
    let productID: Int
    var isAttachedToVM: Bool
    
    init(name: String, vendorID: Int, productID: Int) {
        self.id = UUID()
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.isAttachedToVM = false
    }
}

/// Manages USB device enumeration and attachment to the virtual machine.
/// DORMANT — see the header block. Never instantiated; nothing here runs.
@MainActor
class USBManager: ObservableObject {
    
    // MARK: - Published State
    
    @Published var connectedDevices: [USBDevice] = []
    
    // MARK: - Private Properties
    
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    
    // MARK: - Init
    
    init() {}
    
    // MARK: - Start Monitoring
    
    func startMonitoring() {
        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        
        guard let port = notificationPort else {
            print("AVM: Failed to create IONotificationPort")
            return
        }
        
        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        // Watch for devices being added
        IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matchingDict,
            { userData, iterator in
                guard let userData = userData else { return }
                let manager = Unmanaged<USBManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.handleAddedDevices(iterator: iterator)
                }
            },
            selfPtr,
            &addedIterator
        )
        
        // Drain the initial iterator to arm the notification
        handleAddedDevices(iterator: addedIterator)
        
        // Watch for devices being removed
        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            matchingDict,
            { userData, iterator in
                guard let userData = userData else { return }
                let manager = Unmanaged<USBManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.handleRemovedDevices(iterator: iterator)
                }
            },
            selfPtr,
            &removedIterator
        )
        
        // Drain the initial iterator to arm the notification
        handleRemovedDevices(iterator: removedIterator)
    }
    
    // MARK: - Stop Monitoring
    
    func stopMonitoring() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        connectedDevices.removeAll()
    }
    
    // MARK: - Handle Added Devices
    
    private func handleAddedDevices(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let device = makeUSBDevice(from: service) {
                if !connectedDevices.contains(where: {
                    $0.vendorID == device.vendorID && $0.productID == device.productID
                }) {
                    connectedDevices.append(device)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
    
    // MARK: - Handle Removed Devices
    
    private func handleRemovedDevices(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let device = makeUSBDevice(from: service) {
                connectedDevices.removeAll(where: {
                    $0.vendorID == device.vendorID && $0.productID == device.productID
                })
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
    
    // MARK: - Make USB Device
    
    private func makeUSBDevice(from service: io_service_t) -> USBDevice? {
        let vendorID = IORegistryEntryCreateCFProperty(
            service,
            kUSBVendorID as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Int ?? 0
        
        let productID = IORegistryEntryCreateCFProperty(
            service,
            kUSBProductID as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Int ?? 0
        
        let productName = IORegistryEntryCreateCFProperty(
            service,
            kUSBProductString as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String ?? "Unknown Device"
        
        guard vendorID != 0 || productID != 0 else { return nil }
        
        return USBDevice(name: productName, vendorID: vendorID, productID: productID)
    }
    
    // MARK: - Attach to VM
    
    func attachToVM(_ device: USBDevice) {
        guard let index = connectedDevices.firstIndex(where: { $0.id == device.id }) else { return }
        connectedDevices[index].isAttachedToVM = true
        print("AVM: Attached \(device.name) to VM")
    }
    
    // MARK: - Detach from VM
    
    func detachFromVM(_ device: USBDevice) {
        guard let index = connectedDevices.firstIndex(where: { $0.id == device.id }) else { return }
        connectedDevices[index].isAttachedToVM = false
        print("AVM: Detached \(device.name) from VM")
    }
    
    // MARK: - Cleanup
    
    func cleanup() {
        stopMonitoring()
    }
}
