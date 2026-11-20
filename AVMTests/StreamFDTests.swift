//
//  StreamFDTests.swift
//  AVMTests
//
//  The root helper's check on the socket AVM hands it
//  (avm_usb_prepare_stream_fd in AVMUSBHelper/streamfd.c).
//

import Foundation
import Testing

@Suite("Helper stream descriptor check")
struct StreamFDTests {

    /// Runs the check and returns (accepted, step, detail).
    private func check(_ fd: Int32) -> (ok: Bool, step: String, detail: String) {
        var step = [CChar](repeating: 0, count: 128)
        var detail = [CChar](repeating: 0, count: 512)
        let rc = avm_usb_prepare_stream_fd(fd, &step, step.count, &detail, detail.count)
        return (rc == 0, String(cString: step), String(cString: detail))
    }

    @Test("accepts a connected unix stream socket and sets it up for the pump")
    func acceptsConnectedSocket() {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }

        let result = check(pair[0])
        #expect(result.ok)
        #expect(fcntl(pair[0], F_GETFL) & O_NONBLOCK != 0)
        var noSigPipe: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &size)
        #expect(noSigPipe != 0)
    }

    @Test("accepts a socket whose file was removed after connecting")
    func acceptsUnlinkedConnection() throws {
        let scratch = ScratchFolder()
        let path = scratch.sub("q.sock")
        let listener = listeningSocket(at: path)
        defer { close(listener) }
        let handle = try StreamSocket.connect(path: path).get()
        defer { try? handle.close() }
        unlink(path)
        #expect(check(handle.fileDescriptor).ok)
    }

    @Test("refuses a socket that is not connected")
    func refusesUnconnected() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        let result = check(fd)
        #expect(!result.ok)
        #expect(result.step == "socket")
        #expect(result.detail.contains("not connected"))
    }

    @Test("refuses a datagram socket")
    func refusesDatagram() {
        var pair: [Int32] = [-1, -1]
        socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair)
        defer { close(pair[0]); close(pair[1]) }
        let result = check(pair[0])
        #expect(!result.ok)
        #expect(result.detail.contains("not a stream socket"))
    }

    @Test("refuses a pipe")
    func refusesPipe() {
        var fds: [Int32] = [-1, -1]
        pipe(&fds)
        defer { close(fds[0]); close(fds[1]) }
        let result = check(fds[0])
        #expect(!result.ok)
        #expect(result.detail.contains("not a socket"))
    }

    @Test("refuses a regular file")
    func refusesFile() {
        let fd = open("/etc/hosts", O_RDONLY)
        defer { close(fd) }
        let result = check(fd)
        #expect(!result.ok)
        #expect(result.detail.contains("not a socket"))
    }

    @Test("refuses an unconnected TCP socket")
    func refusesTCP() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        #expect(!check(fd).ok)
    }

    @Test("refuses a missing descriptor")
    func refusesNegative() {
        let result = check(-1)
        #expect(!result.ok)
        #expect(result.detail.contains("no stream socket"))
    }

    @Test("never closes the descriptor it refuses")
    func neverCloses() {
        // The C stream owns closing. The check must leave that to it.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        _ = check(fd)
        #expect(isOpen(fd))
    }

    @Test("works without step and detail buffers")
    func nullBuffers() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        #expect(avm_usb_prepare_stream_fd(fd, nil, 0, nil, 0) == -1)
    }
}
