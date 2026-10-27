// GuestAgent.swift
// AVM — Accessible Virtual Machine
//
// The QEMU guest agent (2026-10-26): a small Windows service AVM installs
// during setup (qemu-ga, from the install DVD), reached through its own
// virtio-serial port, org.qemu.guest_agent.0, on qga.sock in the VM's
// private socket folder.
//
// What AVM uses it for: setting Windows' clock to the Mac's when the Mac
// wakes. A VM paused for sleep (SleepCoordinator.swift) wakes with its
// clock where it stopped, and Windows only corrects it at its next time
// sync, which can be hours; until then, times in mail, files and the
// taskbar are wrong. guest-set-time with the Mac's time fixes it at once.
//
// Windows installed before the agent existed, or with it not yet running,
// simply doesn't answer; AVM waits a few seconds and says nothing more
// than the log line. The protocol is QEMU's: one JSON object per line;
// guest-sync first, so a reply left over from an earlier, timed-out
// request can't be mistaken for this one.

import Foundation

nonisolated enum GuestAgent {

    /// Sends commands in order and returns each reply line, or throws.
    static func run(_ commands: [String], socketPath: String, timeout: TimeInterval = 4) throws -> [String] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError("no socket") }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentError("socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            pathBytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw AgentError("not connected (\(String(cString: strerror(errno))))") }

        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var pending = Data()
        func readLine() throws -> String {
            while true {
                if let newline = pending.firstIndex(of: 0x0a) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    return line
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = read(fd, &chunk, chunk.count)
                guard n > 0 else { throw AgentError(n == 0 ? "closed" : "no answer") }
                pending.append(contentsOf: chunk[0..<n])
            }
        }
        func send(_ line: String) throws {
            let bytes = Array((line + "\n").utf8)
            guard write(fd, bytes, bytes.count) == bytes.count else { throw AgentError("write failed") }
        }

        let id = Int.random(in: 1...Int(Int32.max))
        try send(#"{"execute":"guest-sync","arguments":{"id":\#(id)}}"#)
        while try !readLine().contains("\(id)") {}

        var replies: [String] = []
        for command in commands {
            try send(command)
            replies.append(try readLine())
        }
        return replies
    }

    /// guest-set-time with the Mac's clock, in nanoseconds since 1970.
    static func setTimeCommand(now: Date = Date()) -> String {
        let nanoseconds = Int64(now.timeIntervalSince1970 * 1_000_000_000)
        return #"{"execute":"guest-set-time","arguments":{"time":\#(nanoseconds)}}"#
    }

    struct AgentError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
