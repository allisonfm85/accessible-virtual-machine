// VMProcessScanner.swift
// AVM — Accessible Virtual Machine
//
// Finds the QEMU and swtpm processes that belong to AVM's virtual machines
// by looking at the processes themselves, not at AVM's in-memory state, and
// stops them. Added 2026-11-14 for issue #264.
//
// WHY THIS EXISTS: AVM knew a VM was running only through the live
// VMSession. Anything that outlived that knowledge was invisible: a QEMU
// left running when AVM quit mid-shutdown, or when AVM crashed or was force
// quit. After a relaunch AVM showed such a VM as stopped, let Delete move its
// files to the Trash while QEMU kept running from them, and never cleaned it
// up (the reapers in VMManager only run for the VM being started). In the
// incident behind #264, a Windows VM ran unseen for about 19 hours, holding
// 8 GB of memory and 4 cores.
//
// HOW A PROCESS IS RECOGNIZED: by its arguments. Every QEMU and swtpm AVM
// starts names the VM's own folder, ~/Library/Application Support/AVM/vms/
// <UUID>/ (QEMU through its disk, NVRAM and install media; swtpm through
// --tpmstate), so the UUID is read from that path. This works wherever
// AVM.app lives (a Debug build in DerivedData, a copy in Downloads), and
// it never matches UTM's or anyone else's QEMU. The match is case-blind
// because the path is spelled "vms" in some places and "VMs" in others (see
// VMStore.vmDirectoryURL); the file system treats them as one folder.
// Arguments are read with sysctl(KERN_PROCARGS2), so paths containing
// spaces ("Application Support") arrive whole, with nothing to parse
// around. Only the current user's processes are considered.
//
// The arguments are what QEMU was started with. They still name the old
// folder after Delete has moved it to the Trash, which is exactly the case
// this has to find.
//
// THREADING: everything here is nonisolated and synchronous. A scan is a
// few hundred sysctl calls, a few milliseconds. The waits (stop, shutdown)
// block, so main-actor callers run them in Task.detached.

import Foundation
import Darwin

/// One QEMU or swtpm process belonging to an AVM virtual machine.
nonisolated struct VMProcess: Equatable, Sendable {
    enum Kind: String, Sendable {
        case qemu
        case swtpm
    }

    let pid: pid_t
    let parentPID: pid_t
    let kind: Kind
    let vmID: UUID
    /// QEMU's -m, in megabytes. nil for swtpm, or if it couldn't be read.
    let memoryMB: Int?
    /// QEMU's QMP sockets, from its -chardev arguments. Empty for swtpm.
    let qmpSocketPaths: [String]
    /// True if the parent is another copy of AVM that is running now (a
    /// Debug build next to the release, say). That VM is not a leftover:
    /// the other copy shows it and can stop it.
    let parentIsAnotherAVM: Bool

    /// True if this process is a child of the running AVM, that is, a VM
    /// this copy of AVM started.
    var isOurs: Bool { parentPID == getpid() }

    /// True if no running AVM owns this process. When AVM exits, its
    /// children are handed to launchd, so a leftover's parent is launchd.
    var isLeftover: Bool { !isOurs && !parentIsAnotherAVM }
}

nonisolated enum VMProcessScanner {

    // MARK: - Finding

    /// Every QEMU and swtpm process of the current user that belongs to an
    /// AVM virtual machine.
    static func scan() -> [VMProcess] {
        let ownPID = getpid()
        return userPIDs().compactMap { pid in
            pid == ownPID ? nil : vmProcess(pid: pid)
        }
    }

    /// The processes of one VM.
    static func processes(for vmID: UUID) -> [VMProcess] {
        scan().filter { $0.vmID == vmID }
    }

    /// True if a QEMU process for this VM is running, whoever started it.
    /// This is the check Delete and Reclaim make before touching a folder.
    static func isQEMURunning(for vmID: UUID) -> Bool {
        processes(for: vmID).contains { $0.kind == .qemu }
    }

    /// The processes of virtual machines no running AVM owns, grouped by
    /// VM. These are what the launch check reports.
    static func strays() -> [UUID: [VMProcess]] {
        Dictionary(grouping: scan().filter(\.isLeftover), by: \.vmID)
    }

    /// True if the PID still belongs to the same VM process. Checked before
    /// every signal and wait, because a question about a leftover VM can sit
    /// open for minutes, and a PID that has ended can be given to an
    /// unrelated process. Signalling that one would be far worse than
    /// missing the VM.
    static func isStillRunning(_ process: VMProcess) -> Bool {
        guard let current = vmProcess(pid: process.pid) else { return false }
        return current.kind == process.kind && current.vmID == process.vmID
    }

    // MARK: - Stopping

    /// Asks a QEMU process to shut its guest down, the same request the Stop
    /// button sends (QMP system_powerdown), through the QMP socket QEMU
    /// still listens on. Both of AVM's QMP sockets are server=on,wait=off,
    /// so QEMU accepts a new connection after AVM's went away. Returns
    /// false if no socket answered. A true result means the request was
    /// delivered, not that the guest will act on it; the caller waits for
    /// the process to end.
    static func requestShutdown(of process: VMProcess) -> Bool {
        for path in process.qmpSocketPaths {
            if sendPowerdown(socketPath: path) {
                AVMLog.write("VMProcessScanner: system_powerdown delivered to QEMU pid \(process.pid) for \(process.vmID.uuidString) through \(path)")
                return true
            }
        }
        AVMLog.write("VMProcessScanner: could not deliver system_powerdown to QEMU pid \(process.pid) for \(process.vmID.uuidString) (\(process.qmpSocketPaths.count) socket(s) tried)")
        return false
    }

    /// Stops a VM's processes now: QEMU first (SIGTERM, then SIGKILL if it
    /// is still there after the grace period, the same escalation as
    /// VMManager.forceStopVM, because a guest spinning in HVF has been seen
    /// to shrug off SIGTERM), then swtpm. Blocks until they are gone or
    /// SIGKILL has failed. Returns true if none are left.
    ///
    /// SIGTERM first because QEMU handles it by closing its disk images
    /// cleanly. To the guest it is still a power cut.
    @discardableResult
    static func forceStop(_ processes: [VMProcess], grace: TimeInterval = 3, log: (String) -> Void = { AVMLog.write($0) }) -> Bool {
        // QEMU before swtpm: QEMU talks to swtpm until the moment it exits.
        let ordered = processes.filter { $0.kind == .qemu } + processes.filter { $0.kind == .swtpm }
        var allGone = true
        for process in ordered {
            guard isStillRunning(process) else { continue }
            log("VMProcessScanner: SIGTERM to \(process.kind.rawValue) pid \(process.pid) for \(process.vmID.uuidString)")
            kill(process.pid, SIGTERM)
            if waitForExit(process, timeout: grace) { continue }
            // Checked again just before: SIGKILL must never reach a reused PID.
            guard isStillRunning(process) else { continue }
            log("VMProcessScanner: \(process.kind.rawValue) pid \(process.pid) survived SIGTERM for \(grace) s; sending SIGKILL")
            kill(process.pid, SIGKILL)
            if !waitForExit(process, timeout: 2) {
                log("VMProcessScanner: \(process.kind.rawValue) pid \(process.pid) is STILL running after SIGKILL")
                allGone = false
            }
        }
        return allGone
    }

    /// Polls until the process is gone (or its PID belongs to something
    /// else now) or the timeout passes. Returns true if it is gone.
    static func waitForExit(_ process: VMProcess, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isStillRunning(process) {
            if Date() >= deadline { return false }
            usleep(100_000)
        }
        return true
    }

    // MARK: - Spoken memory size

    /// "8 gigabytes", "1 gigabyte", "512 megabytes": spelled-out units, the
    /// same rule as ContentView.spokenSize (VoiceOver reads "GB" unreliably).
    static func spokenMemory(megabytes: Int) -> String {
        if megabytes >= 1024, megabytes % 1024 == 0 {
            let gb = megabytes / 1024
            return gb == 1 ? "1 gigabyte" : "\(gb) gigabytes"
        }
        if megabytes >= 1024 {
            let gb = Double(megabytes) / 1024
            return "about \(Int(gb.rounded())) gigabytes"
        }
        return "\(megabytes) megabytes"
    }

    // MARK: - Private: process table

    /// PIDs of the current user's processes.
    private static func userPIDs() -> [pid_t] {
        let uid = getuid()
        // First call sizes the buffer; the second fills it. Extra room in
        // case processes start between the two calls.
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        let count = Int(filled) / MemoryLayout<pid_t>.stride
        return pids.prefix(count).filter { $0 > 0 }
    }

    private static func kinfo(pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info
    }

    /// The process's argv, read with KERN_PROCARGS2. Layout: argc (Int32),
    /// the executable path, NUL padding, then argc NUL-terminated strings
    /// (environment follows, and is never read). nil if the process is gone
    /// or belongs to someone else.
    private static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the padding after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    private static func vmProcess(pid: pid_t) -> VMProcess? {
        guard let args = arguments(pid: pid), let program = args.first else { return nil }
        let kind: VMProcess.Kind
        switch (program as NSString).lastPathComponent {
        case "qemu-system-aarch64": kind = .qemu
        case "swtpm": kind = .swtpm
        default: return nil
        }
        // A zombie (exited, not yet reaped by its parent) holds no memory
        // or files, so it counts as gone. Foundation's Process reaps AVM's
        // own children soon after they exit.
        guard let vmID = args.lazy.compactMap(vmIDInPath).first,
              let info = kinfo(pid: pid),
              info.kp_proc.p_stat != SZOMB
        else { return nil }
        let parentPID = info.kp_eproc.e_ppid
        return VMProcess(
            pid: pid,
            parentPID: parentPID,
            kind: kind,
            vmID: vmID,
            memoryMB: kind == .qemu ? memoryMB(in: args) : nil,
            qmpSocketPaths: kind == .qemu ? qmpSocketPaths(in: args) : [],
            parentIsAnotherAVM: parentPID != getpid() && isAVMApp(pid: parentPID)
        )
    }

    /// True if the process is AVM itself: an executable named AVM inside an
    /// app bundle (.../Something.app/Contents/MacOS/AVM), wherever the
    /// bundle lives. launchd (PID 1), the parent of every leftover, is not.
    private static func isAVMApp(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        return path.hasSuffix(".app/Contents/MacOS/AVM")
    }

    /// The UUID after "/Application Support/AVM/vms/" in an argument, if
    /// there is one.
    private static func vmIDInPath(_ argument: String) -> UUID? {
        let marker = "/Application Support/AVM/vms/"
        guard let range = argument.range(of: marker, options: .caseInsensitive) else { return nil }
        let rest = argument[range.upperBound...]
        return UUID(uuidString: String(rest.prefix(36)))
    }

    /// QEMU's -m value in megabytes: "8192M", "8G", or a bare number (QEMU
    /// reads that as megabytes).
    private static func memoryMB(in args: [String]) -> Int? {
        guard let flag = args.firstIndex(of: "-m"), flag + 1 < args.count else { return nil }
        // -m can also be "size=8192M,slots=...", so take the size part.
        var value = args[flag + 1]
        if let size = value.split(separator: ",").first(where: { $0.hasPrefix("size=") }) {
            value = String(size.dropFirst("size=".count))
        } else if let first = value.split(separator: ",").first {
            value = String(first)
        }
        let upper = value.uppercased()
        if upper.hasSuffix("G"), let n = Int(upper.dropLast()) { return n * 1024 }
        if upper.hasSuffix("M"), let n = Int(upper.dropLast()) { return n }
        return Int(upper)
    }

    /// Paths of QEMU's QMP sockets. A -qmp names a chardev ("chardev:ID");
    /// the matching "-chardev socket,id=ID,path=..." holds the path. AVM
    /// starts two (qmp.sock and the diagnostic qmp2.sock), so if one is
    /// busy the other can be tried.
    private static func qmpSocketPaths(in args: [String]) -> [String] {
        var qmpChardevIDs: [String] = []
        for (i, arg) in args.enumerated() where arg == "-qmp" && i + 1 < args.count {
            let value = args[i + 1]
            if value.hasPrefix("chardev:") {
                qmpChardevIDs.append(String(value.dropFirst("chardev:".count)))
            }
        }
        var paths: [String] = []
        for id in qmpChardevIDs {
            for (i, arg) in args.enumerated() where arg == "-chardev" && i + 1 < args.count {
                let fields = args[i + 1].split(separator: ",").map(String.init)
                guard fields.first == "socket", fields.contains("id=\(id)"),
                      let path = fields.first(where: { $0.hasPrefix("path=") })
                else { continue }
                paths.append(String(path.dropFirst("path=".count)))
            }
        }
        return paths
    }

    // MARK: - Private: QMP

    /// Connects to a QMP socket, leaves negotiation mode, and sends
    /// system_powerdown. Blocking, with a 3-second limit on each read and
    /// write. Returns true only if QEMU answered the request with "return".
    private static func sendPowerdown(socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }

        var reader = LineReader(fd: fd)
        // Greeting: {"QMP": {...}}
        guard let greeting = reader.nextLine(), greeting.contains("\"QMP\"") else { return false }
        guard write(fd, "{\"execute\":\"qmp_capabilities\"}\n"),
              reader.nextReply() == true,
              write(fd, "{\"execute\":\"system_powerdown\"}\n"),
              reader.nextReply() == true
        else { return false }
        return true
    }

    private static func write(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    /// Reads newline-terminated QMP messages from a blocking socket.
    private struct LineReader {
        let fd: Int32
        private var pending = [UInt8]()

        init(fd: Int32) { self.fd = fd }

        mutating func nextLine() -> String? {
            while true {
                if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    return line
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { return nil }   // closed, error, or the 3 s timeout
                pending += chunk[..<n]
                if pending.count > 1_000_000 { return nil }
            }
        }

        /// The next command reply, skipping events (a guest that is already
        /// shutting down may send some). true for "return", false for
        /// "error", nil if nothing arrived.
        mutating func nextReply() -> Bool? {
            for _ in 0..<50 {
                guard let line = nextLine() else { return nil }
                if line.contains("\"return\"") { return true }
                if line.contains("\"error\"") { return false }
            }
            return nil
        }
    }
}
