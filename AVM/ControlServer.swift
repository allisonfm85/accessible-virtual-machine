// ControlServer.swift
// AVM — Accessible Virtual Machine
//
// AVM FROM THE COMMAND LINE (2026-10-27), as Hyper-V's PowerShell and
// VMware's vmrun: the running app listens on a socket in its own data
// folder (control.sock, owner-only, and the peer must be the same user),
// and `AVM ctl …` (or Tools/avmctl) sends it one request a line, as JSON,
// and prints the answer:
//
//   avmctl list
//   avmctl status <machine>
//   avmctl start <machine> [--no-window]
//   avmctl stop <machine>            asks it to shut down
//   avmctl save <machine>            saves it, open apps and all
//   avmctl force-stop <machine>
//   avmctl send-file <machine> <file>
//
// <machine> is its name (any case) or id. If AVM isn't running, the tool
// opens it in the background first. Exit status 0 on success, 1 otherwise.

import AppKit

// MARK: - The server, in the app

@MainActor
final class ControlServer {
    static let shared = ControlServer()
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    nonisolated static var socketURL: URL? {
        try? AVMPaths.supportDirectory().appendingPathComponent("control.sock")
    }

    func start() {
        guard fd < 0, let url = Self.socketURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(url.path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0, Self.bind(s, to: url.path) else {
            AVMLog.write("AVM: Control — couldn't listen at \(url.path); avmctl won't reach AVM.")
            if s >= 0 { close(s) }
            return
        }
        chmod(url.path, 0o600)
        listen(s, 8)
        fd = s
        let source = DispatchSource.makeReadSource(fileDescriptor: s, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptOne() }
        }
        source.resume()
        self.source = source
        AVMLog.write("AVM: Control — listening for avmctl.")
    }

    nonisolated static func bind(_ s: Int32, to path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        // Only this user (the folder is theirs too, but be sure).
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
        // On its own thread, with a time limit (2026-10-28, security
        // review): blocking reads on Swift's task threads let a client
        // that sent nothing stop every task in AVM.
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        // No SIGPIPE from a client that left before its reply (2026-10-28,
        // fuzz), on the socket itself as well as process-wide (AVMApp.init).
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global(qos: .utility).async {
            let line = Self.readLine(client)
            Task { @MainActor in
                let reply = await ControlServer.shared.handle(line)
                let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
                DispatchQueue.global(qos: .utility).async {
                    Self.write(client, data + Data("\n".utf8))
                    close(client)
                }
            }
        }
    }

    nonisolated static func readLine(_ fd: Int32) -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 65536, read(fd, &byte, 1) == 1, byte != 10 { data.append(byte) }
        return data
    }

    nonisolated static func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    // MARK: Requests

    private func fail(_ message: String) -> [String: Any] { ["ok": false, "message": message] }

    private func handle(_ line: Data) async -> [String: Any] {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let command = request["command"] as? String else {
            return fail("AVM didn't understand the request.")
        }
        let store = VMStore.shared
        if command == "list" {
            let machines = (store?.configurations ?? []).map(describe)
            return ["ok": true, "machines": machines, "message": machines.isEmpty ? "No virtual machines are set up." : ""]
        }
        let wanted = (request["machine"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard let config = store?.configurations.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame || $0.name.caseInsensitiveCompare(wanted) == .orderedSame
        }) else {
            return fail("There's no virtual machine called \(wanted).")
        }
        let name = config.name
        let session = MachineSessions.shared.session(for: config.id)
        let mac = MacGuestRunner.shared
        let isMac = config.guestOS == .macOS
        AVMLog.write("AVM: Control — \(command) for '\(name)'.")

        switch command {
        case "status":
            return ["ok": true, "machines": [describe(config)], "message": ""]

        case "start":
            // The dashboard's refusals too (2026-10-28, code review): not
            // while its files are being copied, and never a template.
            if let busy = MachineArchiveController.shared.busyMessage(for: config) { return fail(busy) }
            if config.isATemplate { return fail("\(name) is a template. Duplicate it to make a machine to start.") }
            if isMac {
                guard mac.runningID == nil else { return fail("A macOS machine is already running.") }
                // Without taking the keyboard (2026-10-28, fifth audit): a
                // command-line start took it from whatever app the user was
                // in, minutes later.
                mac.start(config, takesKeyboard: false)
                return ["ok": true, "message": "Starting \(name). Your keyboard stays on the Mac until you enter it."]
            }
            if let session {
                // Its real state (2026-10-29, sixth audit): one shutting down
                // was "already running".
                return fail(session.vmState == .stopping ? "\(name) is shutting down. Start it again once it has." : "\(name) is already running.")
            }
            let windowless = request["noWindow"] as? Bool == true || config.startsWithoutWindow
            MachineSessions.shared.start(config, vmStore: store, focusLock: FocusLockManager.shared, windowless: windowless, takesKeyboard: false)
            return ["ok": true, "message": "Starting \(name)\(windowless ? " without a window" : ""). Your keyboard stays on the Mac until you enter it."]

        case "stop":
            if isMac {
                guard mac.runningID == config.id else { return fail("\(name) isn't running.") }
                mac.shutDown()
                return ["ok": true, "message": "Asked \(name) to shut down."]
            }
            guard let session else { return fail("\(name) isn't running.") }
            // Its real state (sixth audit): starting or already shutting
            // down was "isn't running".
            switch session.vmState {
            case .running, .paused: break
            case .starting: return fail("\(name) is still starting. Try again once it's running.")
            case .stopping: return fail("\(name) is already shutting down.")
            default: return fail("\(name) isn't running.")
            }
            // A failure is said (2026-10-28, fourth audit): "Asked X to shut
            // down" was the last word, though X kept running.
            Task {
                do { try await session.stopGracefully() }
                catch { Announcer.shared.announce("\(name) didn't shut down. Reason: \(error.localizedDescription)", tone: .failure) }
            }
            return ["ok": true, "message": "Asked \(name) to shut down."]

        case "save":
            // Never a template (seventh audit): saved with open apps, nothing
            // could start or copy it.
            if config.isATemplate { return fail("\(name) is a template, so it isn't saved with open apps. Shut it down instead.") }
            if isMac {
                guard mac.runningID == config.id, mac.canSave else { return fail("\(name) can't be saved now.") }
                let saved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    mac.saveAndStop { done.resume(returning: $0) }
                }
                return saved ? ["ok": true, "message": "\(name) is saved."] : fail("\(name) couldn't be saved.")
            }
            guard let session else { return fail("\(name) isn't running.") }
            // The right reason (2026-10-28, fifth audit): a save under way,
            // or a machine starting or stopping, isn't a setting.
            guard session.canSave else {
                if session.isSaving { return fail("\(name) is being saved already.") }
                if session.vmState != .running && session.vmState != .paused {
                    return fail("\(name) isn't running; it's \(session.vmState == .starting ? "starting" : "shutting down").")
                }
                return fail("\(name) can't be saved: Save with Open Apps is off for it (see its Settings).")
            }
            return await session.saveAndStop() ? ["ok": true, "message": "\(name) is saved."] : fail("\(name) couldn't be saved.")

        case "force-stop":
            if isMac {
                guard mac.runningID == config.id else { return fail("\(name) isn't running.") }
                mac.forceStop()
                return ["ok": true, "message": "\(name) is turned off."]
            }
            guard let session else { return fail("\(name) isn't running.") }
            session.forceStop()
            return ["ok": true, "message": "\(name) is turned off."]

        // A Windows app's Mac app opened, from the Dock or Applications, or
        // Command-Shift-E in it, or pinned or unpinned (2026-10-30,
        // WindowsApps.swift).
        case "launch-app", "pin-app", "unpin-app":
            guard config.guestOS == .windows else { return fail("\(name) isn't a Windows machine.") }
            let key = request["app"] as? String ?? ""
            let appName = request["name"] as? String ?? "The app"
            guard !key.isEmpty else { return fail("AVM didn't understand the request.") }
            let result = switch command {
            case "launch-app": WindowsApps.shared.launch(machine: config.id, appKey: key, name: appName)
            case "pin-app": await WindowsApps.shared.pin(machine: config.id, appKey: key, name: appName)
            default: WindowsApps.shared.unpin(machine: config.id, appKey: key)
            }
            return ["ok": result.ok, "message": result.message]

        case "send-file":
            guard !isMac else { return fail("Send File works with Windows and Linux machines.") }
            guard let session, session.vmState == .running else { return fail("\(name) isn't running.") }
            guard let path = request["path"] as? String, FileManager.default.isReadableFile(atPath: path) else {
                return fail("That file can't be read.")
            }
            return await session.manager.sendFile(URL(fileURLWithPath: path))
                ? ["ok": true, "message": "Sent \((path as NSString).lastPathComponent) to Downloads in \(name)."]
                : fail("It wasn't sent; AVM said why.")

        default:
            return fail("AVM doesn't know the command \(command).")
        }
    }

    private func describe(_ config: VMConfiguration) -> [String: Any] {
        var state = "shut down"
        if config.guestOS == .macOS {
            if MacGuestRunner.shared.runningID == config.id {
                state = "running"
            } else if let folder = try? config.directoryURL(),
                      FileManager.default.fileExists(atPath: MacGuestFiles(folder: folder).savedState.path) {
                // Saved too (sixth audit): it was "shut down".
                state = "saved"
            }
        } else if let session = MachineSessions.shared.session(for: config.id) {
            switch session.vmState {
            case .starting: state = "starting"
            case .running: state = "running"
            case .paused: state = "paused"
            case .stopping: state = "shutting down"
            case .stopped: state = "shut down"
            case .error(let message): state = "stopped with an error: \(message)"
            }
        } else if QEMUSavedState.looksSaved(config) {
            state = "saved"
        }
        if config.isATemplate { state += ", template" }
        return ["name": config.name, "id": config.id.uuidString, "kind": config.guestOS.displayName, "state": state]
    }
}

// MARK: - The command line

/// `AVM ctl <command> …`: sends one request to the running AVM, opening it
/// in the background if it isn't running, and prints the answer.
enum ControlClient {
    static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.count >= 2, arguments[1] == "ctl" else { return }
        var words = Array(arguments.dropFirst(2))
        guard let command = words.first, command != "help", command != "--help" else {
            print("""
            Usage: avmctl list
                   avmctl status <machine>
                   avmctl start <machine> [--no-window]
                   avmctl stop <machine>
                   avmctl save <machine>
                   avmctl force-stop <machine>
                   avmctl send-file <machine> <file>
            <machine> is its name (quote it if it has spaces) or its id.
            """)
            exit(words.isEmpty ? 1 : 0)
        }
        words.removeFirst()
        var request: [String: Any] = ["command": command]
        let noWindow = words.contains("--no-window")
        words.removeAll { $0 == "--no-window" }
        if noWindow { request["noWindow"] = true }
        if command != "list" {
            guard let machine = words.first else { print("Which machine? See avmctl help."); exit(1) }
            request["machine"] = machine
            if command == "send-file" {
                guard words.count >= 2 else { print("Which file? See avmctl help."); exit(1) }
                request["path"] = URL(fileURLWithPath: words[1]).standardizedFileURL.path
            }
        }
        guard let reply = send(request) else {
            print("AVM didn't answer.")
            exit(1)
        }
        if let machines = reply["machines"] as? [[String: Any]] {
            for m in machines {
                print("\(m["name"] ?? "")\t\(m["kind"] ?? "")\t\(m["state"] ?? "")\t\(m["id"] ?? "")")
            }
        }
        if let message = reply["message"] as? String, !message.isEmpty { print(message) }
        exit(reply["ok"] as? Bool == true ? 0 : 1)
    }

    private static func connect() -> Int32? {
        guard let url = ControlServer.socketURL else { return nil }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(s); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        if !ok { close(s); return nil }
        return s
    }

    private static func send(_ request: [String: Any]) -> [String: Any]? {
        var s = connect()
        if s == nil, let bundleID = Bundle.main.bundleIdentifier {
            // Not running: open it in the background, and wait for it.
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // With an argument, so AVM doesn't start its "start when AVM
            // opens" machine for an avmctl request (2026-10-28, fourth audit):
            // `avmctl list` started it, and it took the keyboard.
            open.arguments = ["-g", "-b", bundleID, "--args", "--from-avmctl"]
            try? open.run()
            open.waitUntilExit()
            for _ in 0..<60 where s == nil {
                Thread.sleep(forTimeInterval: 0.5)
                s = connect()
            }
        }
        guard let s, let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        defer { close(s) }
        ControlServer.write(s, data + Data("\n".utf8))
        let line = ControlServer.readLine(s)
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }
}
