//
//  StreamSocketTests.swift
//  AVMTests
//
//  AVM connects to QEMU's usbredir socket itself, removes the socket
//  file, and hands the connected socket to the root helper.
//

import Foundation
import Testing

@Suite("Stream socket")
struct StreamSocketTests {

    private let scratch = ScratchFolder()

    @Test("connects to a listening socket")
    func connects() throws {
        let path = scratch.sub("q.sock")
        let listener = listeningSocket(at: path)
        defer { close(listener) }
        let handle = try StreamSocket.connect(path: path).get()
        defer { try? handle.close() }
        #expect(handle.fileDescriptor >= 0)
    }

    @Test("the connection outlives the socket file")
    func survivesUnlink() throws {
        // AVM removes the file right after connecting so nobody else can
        // dial in. The connection itself must keep working.
        let path = scratch.sub("q.sock")
        let listener = listeningSocket(at: path)
        defer { close(listener) }
        let handle = try StreamSocket.connect(path: path).get()
        defer { try? handle.close() }
        #expect(unlink(path) == 0)

        let server = accept(listener, nil, nil)
        #expect(server >= 0)
        defer { close(server) }

        let message: [UInt8] = Array("hello".utf8)
        #expect(write(handle.fileDescriptor, message, message.count) == message.count)
        var received = [UInt8](repeating: 0, count: 16)
        let n = read(server, &received, received.count)
        #expect(n == message.count)
        #expect(Array(received.prefix(max(n, 0))) == message)
    }

    @Test("a missing socket fails with a hint about QEMU")
    func missingSocketFails() {
        let path = scratch.sub("nobody-listens.sock")
        switch StreamSocket.connect(path: path) {
        case .success:
            Issue.record("connected to a socket that does not exist")
        case .failure(let failure):
            #expect(failure.detail.contains(path))
            #expect(failure.detail.contains("is QEMU listening there?"))
        }
    }

    @Test("a path too long for a unix socket fails before connecting")
    func tooLongPathFails() {
        let path = "/tmp/" + String(repeating: "x", count: StreamSocket.maxPathBytes)
        switch StreamSocket.connect(path: path) {
        case .success:
            Issue.record("accepted a path longer than a unix socket can hold")
        case .failure(let failure):
            #expect(failure.detail.contains("too long"))
        }
    }

    @Test("macOS unix socket paths hold 104 bytes")
    func maxPathBytes() {
        #expect(StreamSocket.maxPathBytes == 104)
    }
}
