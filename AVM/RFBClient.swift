// RFBClient.swift
// AVM — Accessible Virtual Machine
//
// A small screen-sharing (VNC, RFB 3.8) client for automatic macOS setup
// (2026-10-30, MacAutoSetup.swift). A macOS machine ignores keys a program
// sends to its window (tried 2026-10-26), but Apple's Virtualization
// framework has a VNC server of its own for a machine, and what comes in
// through it is the machine's own keyboard and mouse. This client does only
// what Setup Assistant needs: VNC password sign-in, key presses, mouse
// clicks, and the whole screen as a picture, uncompressed (raw encoding),
// at 32 bits a pixel. Blocking calls on one socket; use it off the main
// thread.

import CommonCrypto
import CoreGraphics
import Foundation

nonisolated final class RFBClient {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let socket: Int32
    private(set) var width = 0
    private(set) var height = 0
    private var pixels = Data()

    /// `wait`: how long a reply may take. Apple's server sends no picture
    /// while nothing changes (eleventh test run), so a short wait means
    /// "unchanged" to a caller that expects a change.
    init(port: UInt16, password: String, wait: Int = 30) throws {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw Failure(message: "no socket") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(socket)
            throw Failure(message: "the machine's screen sharing didn't answer on port \(port)")
        }
        var timeout = timeval(tv_sec: wait, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try handshake(password: password)
    }

    deinit { Darwin.close(socket) }

    // MARK: Sign-in

    private func handshake(password: String) throws {
        let version = try read(12)
        guard String(decoding: version, as: UTF8.self).hasPrefix("RFB ") else { throw Failure(message: "not a screen-sharing server") }
        try write(Data("RFB 003.008\n".utf8))
        let count = Int(try read(1)[0])
        guard count > 0 else { throw Failure(message: "the server refused the connection") }
        let types = [UInt8](try read(count))
        if types.contains(2) {
            try write(Data([2]))
            let challenge = try read(16)
            try write(Self.vncResponse(challenge: challenge, password: password))
        } else if types.contains(1) {
            try write(Data([1]))
        } else {
            throw Failure(message: "no sign-in method in common")
        }
        guard try readUInt32() == 0 else { throw Failure(message: "the screen-sharing password was refused") }
        try write(Data([1]))   // ClientInit: shared
        width = Int(try readUInt16())
        height = Int(try readUInt16())
        _ = try read(16)       // the server's pixel format; ours is set below
        let nameLength = Int(try readUInt32())
        _ = try read(nameLength)
        // SetPixelFormat: 32 bits, 24 deep, little endian, true colour,
        // red at 16, green at 8, blue at 0: B G R x in memory.
        var format = Data([0, 0, 0, 0, 32, 24, 0, 1])
        format += Self.uint16(255) + Self.uint16(255) + Self.uint16(255)
        format += Data([16, 8, 0, 0, 0, 0])
        try write(format)
        // SetEncodings: raw, and DesktopSize so a resize is told, not a mess.
        var encodings = Data([2, 0]) + Self.uint16(2)
        encodings += Self.int32(0) + Self.int32(-223)
        try write(encodings)
    }

    /// VNC authentication: the challenge encrypted with DES, keyed by the
    /// password's first 8 bytes with each byte's bits reversed.
    static func vncResponse(challenge: Data, password: String) -> Data {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, byte) in password.utf8.prefix(8).enumerated() {
            var reversed: UInt8 = 0
            for bit in 0..<8 where byte & (1 << bit) != 0 { reversed |= 1 << (7 - bit) }
            key[i] = reversed
        }
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        challenge.withUnsafeBytes { input in
            _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                        key, 8, nil, input.baseAddress, 16, &out, 16, &moved)
        }
        return Data(out)
    }

    // MARK: Keys and clicks

    func key(_ keysym: UInt32, down: Bool) throws {
        try write(Data([4, down ? 1 : 0, 0, 0]) + Self.uint32(keysym))
    }

    func press(_ keysym: UInt32, with modifiers: [UInt32] = []) throws {
        for modifier in modifiers { try key(modifier, down: true) }
        try key(keysym, down: true)
        try key(keysym, down: false)
        for modifier in modifiers.reversed() { try key(modifier, down: false) }
        usleep(40_000)
    }

    /// Types text as key presses, Shift held for capitals and the US
    /// layout's shifted symbols.
    func type(_ text: String) throws {
        let shifted = Set("~!@#$%^&*()_+{}|:\"<>?")
        for character in text {
            guard let scalar = character.unicodeScalars.first, scalar.isASCII else { continue }
            let needsShift = character.isUppercase || shifted.contains(character)
            try press(UInt32(scalar.value), with: needsShift ? [Self.shift] : [])
        }
    }

    func click(x: Int, y: Int) throws {
        let x = UInt16(clamping: x), y = UInt16(clamping: y)
        try write(Data([5, 0]) + Self.uint16(x) + Self.uint16(y))
        usleep(60_000)
        try write(Data([5, 1]) + Self.uint16(x) + Self.uint16(y))
        usleep(60_000)
        try write(Data([5, 0]) + Self.uint16(x) + Self.uint16(y))
        usleep(60_000)
    }

    static let returnKey: UInt32 = 0xff0d
    static let tab: UInt32 = 0xff09
    static let escape: UInt32 = 0xff1b
    static let space: UInt32 = 0x20
    static let shift: UInt32 = 0xffe1
    static let backspace: UInt32 = 0xff08
    /// Keys a Mac might take as Command through screen sharing: Super,
    /// Meta, Alt. Super came through as nothing on macOS 27.2 (fifth
    /// test run), so MacAutoSetup tries each (findCommandKey).
    static let commandCandidates: [UInt32] = [0xffeb, 0xffe7, 0xffe9]
    static let f5: UInt32 = 0xffc2

    // MARK: The screen

    /// The whole screen now, as a picture.
    func screen() throws -> CGImage {
        try write(Data([3, 0]) + Self.uint16(0) + Self.uint16(0) + Self.uint16(UInt16(width)) + Self.uint16(UInt16(height)))
        // Messages until a framebuffer update has arrived.
        while true {
            let type = try read(1)[0]
            switch type {
            case 0:
                try readUpdate()
                guard let image = makeImage() else { throw Failure(message: "no picture of the screen") }
                return image
            case 1:   // colour map entries: not with true colour, but skipped
                _ = try read(3)
                let count = Int(try readUInt16())
                _ = try read(count * 6)
            case 2:   // bell
                continue
            case 3:   // the guest's clipboard
                _ = try read(3)
                _ = try read(Int(try readUInt32()))
            default:
                throw Failure(message: "an unexpected screen-sharing message (\(type))")
            }
        }
    }

    private func readUpdate() throws {
        _ = try read(1)
        let rects = Int(try readUInt16())
        if pixels.count != width * height * 4 { pixels = Data(count: width * height * 4) }
        for _ in 0..<rects {
            let x = Int(try readUInt16()), y = Int(try readUInt16())
            let w = Int(try readUInt16()), h = Int(try readUInt16())
            let encoding = try readInt32()
            switch encoding {
            case 0:
                let data = try read(w * h * 4)
                data.withUnsafeBytes { source in
                    pixels.withUnsafeMutableBytes { target in
                        for row in 0..<h where y + row < height {
                            let count = min(w, width - x) * 4
                            guard count > 0 else { continue }
                            memcpy(target.baseAddress! + ((y + row) * width + x) * 4,
                                   source.baseAddress! + row * w * 4, count)
                        }
                    }
                }
            case -223:   // DesktopSize: the screen is now w by h
                width = w
                height = h
                pixels = Data(count: width * height * 4)
            default:
                throw Failure(message: "an unexpected screen encoding (\(encoding))")
            }
        }
    }

    private func makeImage() -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Bytes

    private func write(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            while sent < data.count {
                let n = Darwin.send(socket, buffer.baseAddress! + sent, data.count - sent, 0)
                guard n > 0 else { throw Failure(message: "the screen-sharing connection closed") }
                sent += n
            }
        }
    }

    private func read(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var got = 0
        try data.withUnsafeMutableBytes { buffer in
            while got < count {
                let n = Darwin.recv(socket, buffer.baseAddress! + got, count - got, 0)
                guard n > 0 else { throw Failure(message: "the screen-sharing connection closed or timed out") }
                got += n
            }
        }
        return data
    }

    private func readUInt16() throws -> UInt16 { let d = try read(2); return UInt16(d[0]) << 8 | UInt16(d[1]) }
    private func readUInt32() throws -> UInt32 { let d = try read(4); return d.reduce(0) { $0 << 8 | UInt32($1) } }
    private func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }
    private static func uint16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }
    private static func uint32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]) }
    private static func int32(_ v: Int32) -> Data { uint32(UInt32(bitPattern: v)) }
}
