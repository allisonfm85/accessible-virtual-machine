//
//  HelperProtocolTests.swift
//  AVMTests
//
//  The XPC payloads between AVM and the root helper must survive secure
//  coding, the only way XPC will carry them.
//

import Foundation
import Testing

@Suite("Helper XPC contract")
struct HelperProtocolTests {

    private func device(serial: String? = "ABC123", product: String = "ATR2100x-USB Microphone") -> AVMUSBDeviceIdentity {
        AVMUSBDeviceIdentity(vendorID: 0x0909, productID: 0x004d,
                             busNumber: 2, deviceAddress: 7,
                             serialNumber: serial, productString: product)
    }

    private func roundTrip<T: NSObject & NSSecureCoding>(_ value: T) throws -> T? {
        let data = try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
        return try NSKeyedUnarchiver.unarchivedObject(ofClasses: [T.self, AVMUSBDeviceIdentity.self], from: data) as? T
    }

    @Test("a device identity survives secure coding")
    func identityRoundTrip() throws {
        let original = device()
        let decoded = try #require(try roundTrip(original))
        #expect(decoded == original)
        #expect(decoded.serialNumber == "ABC123")
        #expect(decoded.productString == original.productString)
    }

    @Test("a device without a serial number survives secure coding")
    func identityWithoutSerial() throws {
        let decoded = try #require(try roundTrip(device(serial: nil)))
        #expect(decoded.serialNumber == nil)
    }

    @Test("a status row survives secure coding")
    func statusRoundTrip() throws {
        let row = AVMUSBDeviceStatus(device: device(), state: .attached,
                                     streamSocketPath: "/tmp/avm-501/X/usbredir-5.sock")
        let decoded = try #require(try roundTrip(row))
        #expect(decoded.device == row.device)
        #expect(decoded.state == .attached)
        #expect(decoded.streamSocketPath == row.streamSocketPath)
    }

    @Test("equality is bus address plus vendor and product, not serial")
    func equality() {
        #expect(device(serial: "A") == device(serial: "B"))
        let elsewhere = AVMUSBDeviceIdentity(vendorID: 0x0909, productID: 0x004d,
                                             busNumber: 2, deviceAddress: 8,
                                             serialNumber: "ABC123", productString: "ATR2100x-USB Microphone")
        #expect(device() != elsewhere)
        #expect(Set([device(serial: "A"), device(serial: "B")]).count == 1)
    }

    @Test("a device with no product string is still named")
    func displayNameFallback() {
        #expect(device(product: "").displayName == "USB device 0909:004d")
        #expect(device().displayName == "ATR2100x-USB Microphone")
    }

    @Test("the contract version names the descriptor-passing attach")
    func protocolVersion() {
        #expect(AVMUSBHelperNames.protocolVersion == "0.3.0-fd")
    }

    @Test("attach takes a socket, not a path")
    func attachSelector() {
        // The old path-taking selector must be gone from the contract, so
        // a root helper can never be asked to dial a path again.
        let iface = AVMUSBHelperInterfaces.helper()
        #expect(iface.protocol === (AVMUSBHelperProtocol.self as Protocol))
        let newSelector = NSSelectorFromString("attach:stream:streamLabel:reply:")
        let oldSelector = NSSelectorFromString("attach:streamSocketPath:reply:")
        let proto = AVMUSBHelperProtocol.self as Protocol
        #expect(protocol_getMethodDescription(proto, newSelector, true, true).name != nil)
        #expect(protocol_getMethodDescription(proto, oldSelector, true, true).name == nil)
    }
}
