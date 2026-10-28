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

    /// One lock per machine's agent: its channel takes one client at a
    /// time, and a second connection is refused (2026-10-27, MEASURED:
    /// printers and a status check at once got "Connection refused"). AVM's
    /// own calls take turns here; a refusal from anyone else is retried.
    private static let locksLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSLock] = [:]
    private static func lock(for path: String) -> NSLock {
        locksLock.lock(); defer { locksLock.unlock() }
        if let lock = locks[path] { return lock }
        let lock = NSLock()
        locks[path] = lock
        return lock
    }

    /// Sends commands in order and returns each reply line, or throws.
    /// `replies` false: the commands are sent after the sync and no answer
    /// is read (guest-shutdown answers with nothing, 2026-10-28).
    static func run(_ commands: [String], socketPath: String, timeout: TimeInterval = 4, replies: Bool = true) throws -> [String] {
        let lock = lock(for: socketPath)
        lock.lock(); defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(15)
        while true {
            do {
                return try once(commands, socketPath: socketPath, timeout: timeout, replies: replies)
            } catch let error as AgentError where error.refused && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    private static func once(_ commands: [String], socketPath: String, timeout: TimeInterval, replies wantReplies: Bool = true) throws -> [String] {
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
        guard connected == 0 else {
            let refused = errno == ECONNREFUSED || errno == EAGAIN
            var error = AgentError("not connected (\(String(cString: strerror(errno))))")
            error.refused = refused
            throw error
        }

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
                // Bounded (2026-10-28, security review): a guest sending
                // bytes with no line end mustn't grow this without limit.
                guard pending.count < 16 * 1024 * 1024 else { throw AgentError("the guest agent sent too much without an answer") }
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
        var skipped = 0
        while try !readLine().contains("\(id)") {
            skipped += 1
            guard skipped < 1000 else { throw AgentError("the guest agent didn't answer the sync") }
        }

        var replies: [String] = []
        for command in commands {
            try send(command)
            if wantReplies { replies.append(try readLine()) }
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
        /// The channel was busy with another client: worth a retry.
        var refused = false
        init(_ message: String) { errorDescription = message }
    }
}
