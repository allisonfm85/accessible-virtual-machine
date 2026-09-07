//
//  AVMUSBHelperProtocol.swift
//  AVM
//
//  The XPC contract between AVM and the root USB helper.
//  This file is compiled into BOTH targets. Change it in one place.
//
//  The helper does four things: claim, stream, release, report.
//  It never speaks. It never decides policy. It never lists devices.
//  AVM does all of that. The helper supplies honest state and AVM
//  turns that state into announcements.
//
//  Every call and every event names its device. Multiple devices can
//  be attached at once, each with its own stream socket to QEMU.
//
//  Everything here is nonisolated on purpose. XPC decodes payloads and
//  delivers calls on its own threads, and the AVM target defaults new
//  types to the main actor. These types must not inherit that.
//

import Foundation

// MARK: - Names

nonisolated public enum AVMUSBHelperNames {
    /// launchd label and Mach service name. Three L's on purpose,
    /// same as the bundle identifier. Don't fix it.
    public static let machServiceName = "com.alllisonmeloy.AVM.usbhelper"

    /// The plist AVM registers with SMAppService.daemon(plistName:).
    /// Lives at AVM.app/Contents/Library/LaunchDaemons/.
    public static let launchdPlistName = "com.alllisonmeloy.AVM.usbhelper.plist"

    /// The bundle identifier of the app that is allowed to talk to the helper.
    public static let clientBundleIdentifier = "com.alllisonmeloy.AVM"
}

// MARK: - Device identity

/// Names one physical USB device for the life of one plug-in.
/// Bus and address are what libusb uses to find it again. Vendor,
/// product and serial are what a person recognizes.
@objc(AVMUSBDeviceIdentity)
nonisolated public final class AVMUSBDeviceIdentity: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { true }

    @objc public let vendorID: UInt16
    @objc public let productID: UInt16
    @objc public let busNumber: UInt8
    @objc public let deviceAddress: UInt8
    @objc public let serialNumber: String?
    @objc public let productString: String

    @objc public init(vendorID: UInt16,
                      productID: UInt16,
                      busNumber: UInt8,
                      deviceAddress: UInt8,
                      serialNumber: String?,
                      productString: String) {
        self.vendorID = vendorID
        self.productID = productID
        self.busNumber = busNumber
        self.deviceAddress = deviceAddress
        self.serialNumber = serialNumber
        self.productString = productString
        super.init()
    }

    public required init?(coder: NSCoder) {
        vendorID = UInt16(truncatingIfNeeded: coder.decodeInteger(forKey: "vendorID"))
        productID = UInt16(truncatingIfNeeded: coder.decodeInteger(forKey: "productID"))
        busNumber = UInt8(truncatingIfNeeded: coder.decodeInteger(forKey: "busNumber"))
        deviceAddress = UInt8(truncatingIfNeeded: coder.decodeInteger(forKey: "deviceAddress"))
        serialNumber = coder.decodeObject(of: NSString.self, forKey: "serialNumber") as String?
        guard let product = coder.decodeObject(of: NSString.self, forKey: "productString") as String? else {
            return nil
        }
        productString = product
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int(vendorID), forKey: "vendorID")
        coder.encode(Int(productID), forKey: "productID")
        coder.encode(Int(busNumber), forKey: "busNumber")
        coder.encode(Int(deviceAddress), forKey: "deviceAddress")
        coder.encode(serialNumber as NSString?, forKey: "serialNumber")
        coder.encode(productString as NSString, forKey: "productString")
    }

    /// "0909:004d" style, the way probe3 and lsusb print it.
    @objc public var vidPidString: String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    /// What announcements call the device. Product string first,
    /// vendor:product as the fallback so no device is ever nameless.
    @objc public var displayName: String {
        productString.isEmpty ? "USB device \(vidPidString)" : productString
    }

    /// Two identities are the same device if they sit at the same
    /// bus address with the same vendor and product. Serial is not
    /// part of equality because many devices ship without one.
    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? AVMUSBDeviceIdentity else { return false }
        return vendorID == other.vendorID
            && productID == other.productID
            && busNumber == other.busNumber
            && deviceAddress == other.deviceAddress
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(vendorID)
        hasher.combine(productID)
        hasher.combine(busNumber)
        hasher.combine(deviceAddress)
        return hasher.finalize()
    }

    public override var description: String {
        "\(displayName) [\(vidPidString) bus \(busNumber) addr \(deviceAddress)]"
    }
}

// MARK: - Device state

/// Where one device is in its life with the helper.
/// The helper reports these. AVM decides what to say about them.
@objc(AVMUSBDeviceState)
nonisolated public enum AVMUSBDeviceState: Int {
    /// Claim in progress. Nothing to announce yet unless it takes too long.
    case attaching = 0
    /// Claimed and streaming to QEMU.
    case attached = 1
    /// Release in progress.
    case releasing = 2
    /// Released cleanly. macOS has the device back.
    case released = 3
    /// The claim failed. The detail string names the failing step.
    case failed = 4
    /// The device disappeared from the bus while attached.
    case yanked = 5
}

// MARK: - Status entry

/// One row of the helper's status report: a device and its state.
@objc(AVMUSBDeviceStatus)
nonisolated public final class AVMUSBDeviceStatus: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { true }

    @objc public let device: AVMUSBDeviceIdentity
    @objc public let state: AVMUSBDeviceState
    @objc public let streamSocketPath: String

    @objc public init(device: AVMUSBDeviceIdentity,
                      state: AVMUSBDeviceState,
                      streamSocketPath: String) {
        self.device = device
        self.state = state
        self.streamSocketPath = streamSocketPath
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let device = coder.decodeObject(of: AVMUSBDeviceIdentity.self, forKey: "device"),
              let state = AVMUSBDeviceState(rawValue: coder.decodeInteger(forKey: "state")),
              let path = coder.decodeObject(of: NSString.self, forKey: "streamSocketPath") as String?
        else { return nil }
        self.device = device
        self.state = state
        self.streamSocketPath = path
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(device, forKey: "device")
        coder.encode(state.rawValue, forKey: "state")
        coder.encode(streamSocketPath as NSString, forKey: "streamSocketPath")
    }
}

// MARK: - Helper side (AVM calls these)

@objc(AVMUSBHelperProtocol)
nonisolated public protocol AVMUSBHelperProtocol {
    /// Claim a device and stream it to the QEMU usbredir socket at
    /// streamSocketPath. QEMU listens; the helper dials.
    /// Reply: success, failing step (nil on success), detail.
    /// Attach calls stack. Each device is an independent claim.
    func attach(_ device: AVMUSBDeviceIdentity,
                streamSocketPath: String,
                reply: @escaping (Bool, String?, String?) -> Void)

    /// Release one device. Reply: success, detail.
    func detach(_ device: AVMUSBDeviceIdentity,
                reply: @escaping (Bool, String?) -> Void)

    /// Everything the helper currently holds, with states.
    func status(reply: @escaping ([AVMUSBDeviceStatus]) -> Void)

    /// Helper build identity, so AVM can tell a stale helper from a
    /// current one after an update. Reply: version string.
    func helperVersion(reply: @escaping (String) -> Void)
}

// MARK: - AVM side (the helper calls this back)

@objc(AVMUSBHelperClientProtocol)
nonisolated public protocol AVMUSBHelperClientProtocol {
    /// Fired for every state change of every device. Always carries
    /// the device it is about. Detail names a step or a reason when
    /// there is one.
    func stateChanged(_ device: AVMUSBDeviceIdentity,
                      state: AVMUSBDeviceState,
                      detail: String?)
}

// MARK: - Interfaces with secure-coding class lists

nonisolated public enum AVMUSBHelperInterfaces {
    /// The interface AVM sets as remoteObjectInterface and the helper
    /// sets as exportedInterface.
    public static func helper() -> NSXPCInterface {
        let iface = NSXPCInterface(with: AVMUSBHelperProtocol.self)
        // Swift can't put metatypes in a Set directly. Build it as an
        // NSSet and bridge. This is the accepted idiom for setClasses.
        let statusClasses = NSSet(array: [NSArray.self, AVMUSBDeviceStatus.self, AVMUSBDeviceIdentity.self]) as! Set<AnyHashable>
        iface.setClasses(statusClasses,
                         for: #selector(AVMUSBHelperProtocol.status(reply:)),
                         argumentIndex: 0,
                         ofReply: true)
        return iface
    }

    /// The interface the helper sets as remoteObjectInterface and AVM
    /// sets as exportedInterface.
    public static func client() -> NSXPCInterface {
        NSXPCInterface(with: AVMUSBHelperClientProtocol.self)
    }
}
