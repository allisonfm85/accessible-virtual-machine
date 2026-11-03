// GuestWatchLogic.swift
// AVM — Accessible Virtual Machine
//
// What GuestWatch.swift decides from (2026-10-31): its settings, what a
// machine's process list says is running, and whether its screen changed
// and which lines on it are new. Apart from the loop, so the logic tests
// reach it.

import CoreGraphics
import Foundation

nonisolated enum GuestWatchSettings {
    static let speakScreenKey = "AVMSpeakScreenChanges"
    static let restartReaderKey = "AVMRestartStoppedScreenReader"
    static let pointBeforeUpdatesKey = "AVMRestorePointBeforeUpdates"
    /// AVM's updates held while the keyboard is in a machine whose screen
    /// reader is running, and said when it comes back (Announcer, 2026-10-31).
    static let holdWhileInMachineKey = "AVMHoldUpdatesInMachine"
    /// Off by default: each new machine gets the saved screen reader setup.
    static let useSavedSetupKey = "AVMUseSavedScreenReaderSetup"

    /// On unless turned off, except the restore point before updates: off
    /// until turned on (2026-10-31). Twice in tests, Windows didn't come
    /// back from the restart that followed a point taken while it ran, and
    /// came back every time without one; on until that's understood would
    /// strand someone mid-update.
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? (key != pointBeforeUpdatesKey)
    }
}

// MARK: - What the machine is running

/// The screen readers and desktop seen in a machine's process list.
nonisolated struct GuestProcesses: Equatable {
    /// A user is signed in: Windows' Explorer, or a Linux desktop.
    var signedIn = false
    /// The screen readers running, by their spoken names.
    var screenReaders: Set<String> = []
    /// GNOME, where Orca has a shortcut to start it.
    var gnome = false
    /// Different after every restart (2026-10-31): Windows' smss.exe, the
    /// first process it starts, by its process number; Linux's boot_id.
    /// A restart shorter than the 16 seconds between listings got no
    /// "no answer" in between, so it went unnoticed.
    var boot: String?

    /// From `tasklist /fo csv /nh` (Windows), or the boot_id and then
    /// `ps -eo comm` (Linux).
    static func parse(_ listing: String, windows: Bool) -> GuestProcesses {
        var found = GuestProcesses()
        for raw in listing.split(whereSeparator: \.isNewline) {
            var name = raw.trimmingCharacters(in: .whitespaces)
            if windows {
                // "nvda.exe","1234","Console","1","50,000 K"
                let fields = name.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                guard name.hasPrefix("\""), let first = fields.first else { continue }
                name = first
                if name.lowercased() == "smss.exe", fields.count > 1 { found.boot = fields[1] }
            } else if found.boot == nil, name.count == 36, name.filter({ $0 == "-" }).count == 4 {
                found.boot = name
                continue
            }
            switch name.lowercased() {
            case "explorer.exe": found.signedIn = true
            case "nvda.exe": found.screenReaders.insert("NVDA")
            case "jfw.exe": found.screenReaders.insert("JAWS")
            case "narrator.exe": found.screenReaders.insert("Narrator")
            case "orca": found.screenReaders.insert("Orca")
            case "gnome-shell": found.signedIn = true; found.gnome = true
            case "plasmashell", "xfce4-session", "mate-session", "cinnamon", "lxqt-session": found.signedIn = true
            default: break
            }
        }
        return found
    }
}

// MARK: - New text on the screen

nonisolated enum ScreenChange {
    /// A screen as 64 by 36 grey levels, enough to tell a new page from a
    /// blinking cursor or a spinner.
    static func thumbnail(of image: CGImage) -> [UInt8]? {
        let w = 64, h = 36
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? pixels : nil
    }

    /// True when enough of the thumbnail moved to be a new screen: a
    /// spinner or a cursor moves a few cells, a new page many.
    static func isNewScreen(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return true }
        let moved = zip(a, b).filter { abs(Int($0) - Int($1)) > 24 }.count
        return moved > a.count / 50
    }

    /// A line as compared: lower case, letters only, so "Working on
    /// updates 23%" and "... 24%" are the same line, said once.
    static func key(_ line: String) -> String {
        String(line.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) })
    }

    /// The lines worth saying: new since the last screen said, and with
    /// some words in them (not a lone digit or a stray mark).
    static func newLines(_ lines: [String], after said: Set<String>) -> [String] {
        var seen = Set<String>()
        return lines.filter { line in
            let k = key(line)
            guard k.count >= 3, !said.contains(k), !seen.contains(k) else { return false }
            seen.insert(k)
            return true
        }
    }

    /// Windows' stop screen, said as what it is.
    static func isStopScreen(_ lines: [String]) -> Bool {
        lines.contains { $0.localizedCaseInsensitiveContains("ran into a problem") }
            && lines.contains { $0.localizedCaseInsensitiveContains("stop code") }
    }
}

/// "This machine looks stuck" (2026-11-01, the user's request): a person who
/// can't see a frozen boot can't know to reset it. A sign of life is its agent
/// answering, or its screen changing. Said once per freeze.
nonisolated struct StuckWatch: Sendable {
    /// Long enough for Windows' slowest quiet restarts, as a first restart
    /// after the 3D driver, which take several minutes.
    static let limit: TimeInterval = 600
    /// Longer than this between looks, AVM wasn't looking: the Mac slept, or
    /// the machine was paused.
    static let longestGap: TimeInterval = 60

    enum Change: Equatable, Sendable { case none, stuck, alive }

    let limit: TimeInterval
    private var lastSign: Date
    private var lastLook: Date
    private var told = false

    init(limit: TimeInterval = StuckWatch.limit, now: Date = Date()) {
        self.limit = limit
        lastSign = now
        lastLook = now
    }

    mutating func look(agentAnswered: Bool, screenChanged: Bool, now: Date = Date()) -> Change {
        defer { lastLook = now }
        if agentAnswered || screenChanged || now.timeIntervalSince(lastLook) > Self.longestGap {
            lastSign = now
            if told, agentAnswered || screenChanged {
                told = false
                return .alive
            }
            return .none
        }
        guard !told, now.timeIntervalSince(lastSign) >= limit else { return .none }
        told = true
        return .stuck
    }
}

/// What Check This Machine found, from its script's key=value lines.
nonisolated struct MachineCheckResult: Sendable {
    struct Problem: Equatable, Sendable {
        let what: String
        let next: String
    }
    private(set) var problems: [Problem] = []
    private(set) var fine: [String] = []

    init(agentAnswered: Bool, output: String, windows: Bool, soundLevels: (left: Int, right: Int)?) {
        guard agentAnswered else {
            problems.append(Problem(what: "it isn't answering AVM", next: "wait for it to finish starting. If it's been more than a few minutes, press Command-Shift-R to reset it"))
            return
        }
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        fine.append("it's answering")
        let signedIn = values["signedin"] == "1"
        if signedIn {
            fine.append("someone is signed in")
        } else {
            problems.append(Problem(what: "nobody is signed in", next: "press Command-Shift-E and sign in. Its screen reader and clipboard start after that"))
        }
        if signedIn {
            if let reader = values["reader"], !reader.isEmpty {
                let names = reader.split(separator: ",").map { Self.readerName(String($0).lowercased()) }
                fine.append("\(names.joined(separator: " and ")) is running")
            } else {
                problems.append(Problem(what: "no screen reader is running", next: windows ? "press Command-Shift-E, then Control-Alt-N to start NVDA" : "press Command-Shift-E, then Super-Alt-S to start Orca"))
            }
        }
        // Linux has no sound to ask about until someone's signed in.
        if signedIn || windows {
            if values["sound"] == "1" && values["sounddevice"] == "1" {
                fine.append("sound is working")
            } else {
                problems.append(Problem(what: "its sound isn't working", next: "restart it. If that doesn't help, choose Report a Problem in the Help menu"))
            }
        }
        if let soundLevels {
            if soundLevels.left == 0 && soundLevels.right == 0 {
                problems.append(Problem(what: "its volume is set to zero in AVM", next: "turn it up in its Settings, under Display and Sound"))
            } else if soundLevels.left == 0 {
                fine.append("its sound goes to your right ear only")
            } else if soundLevels.right == 0 {
                fine.append("its sound goes to your left ear only")
            }
        }
        if signedIn {
            if values["clipboard"] == "1" {
                fine.append("the clipboard agent is running")
            } else {
                problems.append(Problem(what: "the clipboard agent isn't running", next: windows ? "install spice-vdagent from spice-space.org in it" : "sign out of it and back in"))
            }
        }
        if values["sharedfolder"] == "1" {
            fine.append("the shared folder service is running")
        } else {
            problems.append(Problem(what: "the shared folder service isn't running", next: windows ? "install spice-webdavd from spice-space.org in it" : "choose Virtual Machine, Repair for AVM, if it's offered, or restart it"))
        }
    }

    private static func readerName(_ raw: String) -> String {
        switch raw {
        case "nvda": return "NVDA"
        case "jfw": return "JAWS"
        case "narrator": return "Narrator"
        case "orca": return "Orca"
        default: return raw
        }
    }

    func words(machine: String) -> String {
        if problems.isEmpty { return "\(machine) looks good: \(fine.joined(separator: ", "))." }
        let list = problems.map { "\($0.what). Next: \($0.next)." }.joined(separator: " ")
        let count = problems.count == 1 ? "one problem" : "\(problems.count) problems"
        return "\(machine) has \(count): \(list)" + (fine.isEmpty ? "" : " Fine: \(fine.joined(separator: ", ")).")
    }
}

/// Control with the Left and Right arrows, which the Mac can take before a
/// machine sees them (2026-11-02, the user's report): macOS has them on by
/// default for moving between Spaces. In Windows and Linux they move by word.
nonisolated enum MacSpacesShortcuts {
    /// Apple's numbers for "Move left a space" and "Move right a space", in
    /// com.apple.symbolichotkeys, with the key codes they use by default.
    private static let shortcuts = [("79", 123), ("81", 124)]

    /// An entry that isn't there is a shortcut still at its default, so on.
    /// One moved to other keys is out of the way.
    static func takeControlArrows(_ hotKeys: [String: Any]?) -> Bool {
        shortcuts.contains { number, keyCode in
            guard let entry = hotKeys?[number] as? [String: Any] else { return true }
            if (entry["enabled"] as? NSNumber)?.boolValue == false { return false }
            guard let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else { return true }
            let modifiers = parameters[2].intValue
            let control = 0x40000, otherModifiers = 0x20000 | 0x80000 | 0x100000
            return parameters[1].intValue == keyCode && modifiers & control != 0 && modifiers & otherModifiers == 0
        }
    }

    static func words(machine: String) -> String {
        "Your Mac keeps Control-Left Arrow and Control-Right Arrow for moving between Spaces, so they won't reach \(machine), where they move by word. Next: in System Settings, go to Keyboard, Keyboard Shortcuts, Mission Control, and turn off Move left a space and Move right a space."
    }
}

/// Which of the feed's early releases this copy of AVM takes.
nonisolated enum UpdateChannels {
    static let earlyKey = "AVMEarlyUpdates"
    static var allowed: Set<String> {
        UserDefaults.standard.bool(forKey: earlyKey) ? ["early"] : []
    }
}

/// How a running QEMU is doing on the Mac, and what's worth saying about it.
nonisolated struct MachineHealth: Sendable {
    struct Reading: Sendable {
        var openFiles: Int
        var fileLimit: Int
        var memoryBytes: UInt64
        var macMemoryBytes: UInt64
        var faults: Int
    }
    struct Warning: Equatable, Sendable {
        let kind: String
        let words: String
    }
    let warnings: [Warning]

    init(_ reading: Reading) {
        var found: [Warning] = []
        if reading.fileLimit > 0, reading.openFiles * 10 >= reading.fileLimit * 8 {
            found.append(Warning(kind: "files", words: "it's near the most connections and files your Mac allows it, \(reading.openFiles) of \(reading.fileLimit). New connections may fail. Next: close what's using the network in it, or restart it."))
        }
        if reading.macMemoryBytes > 0, reading.memoryBytes * 10 >= reading.macMemoryBytes * 9 {
            found.append(Warning(kind: "memory", words: "it's using nearly all your Mac's memory. Next: shut it down and give it less, in its Settings."))
        }
        if reading.faults > 0 {
            found.append(Warning(kind: "faults", words: "the program that runs it, QEMU, has reported a fault since it started. It may stop working. Next: save your work, and choose Report a Problem in the Help menu."))
        }
        warnings = found
    }

    /// For Check This Machine.
    var words: String {
        warnings.isEmpty ? "AVM's own health check found nothing wrong." : "AVM's own health check: " + warnings.map(\.words).joined(separator: " ")
    }
}

/// QEMU's messages that say nothing's wrong (2026-11-02): a 3D session's log was
/// nine tenths these. DXMT's unimplemented Windows calls and virglrenderer's
/// debug lines, not its errors. Whole lines, so anything else still gets through.
nonisolated enum QEMUStderrNoise {
    private static let harmless = [
        "warn:  GetCurrentThread not implemented", "warn:  SetThreadPriority not implemented",
        "warn:  GetModuleHandle not implemented", "warn:  D3DKMTOpenAdapterFromLuid not implemented",
        "warn:  Failed to open D3DKMT adapter", "warn:  D3D11Resource(tex2d): Unknown interface query",
        "err:   Not implemented", "info:  ",
    ]

    static func isHarmless(_ line: String) -> Bool {
        if harmless.contains(where: { line.hasPrefix($0) }) { return true }
        guard line.contains("virgl_render_server["), line.contains("<Debug>:") else { return false }
        let lower = line.lowercased()
        if lower.contains("d3d12") { return true }
        return !lower.contains("error") && !lower.contains("fail")
    }

    /// The chunk with its harmless lines out, and how many went. Nil when
    /// nothing's left.
    static func filter(_ chunk: String) -> (kept: String?, dropped: Int) {
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { !isHarmless($0) }
        let dropped = lines.count - kept.count
        if dropped == 0 { return (chunk, 0) }
        let text = kept.joined(separator: "\n")
        return (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text, dropped)
    }
}

/// Whether the Mac can reach the IPv6 internet, and QEMU's network line from it.
nonisolated enum MacIPv6 {
    /// A global address, 2000::/3. A router's own fd00:: addresses aren't one:
    /// a Mac can have those with an ISP that has no IPv6.
    static func isGlobal(_ address: [UInt8]) -> Bool {
        address.count == 16 && address[0] & 0xE0 == 0x20
    }

    /// Connecting a UDP socket sends nothing: it only asks for a route, and
    /// which of the Mac's addresses that route would use.
    static var isReachable: Bool {
        let fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var target = sockaddr_in6()
        target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        target.sin6_family = sa_family_t(AF_INET6)
        target.sin6_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET6, "2606:4700:4700::1111", &target.sin6_addr) == 1 else { return false }
        let size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) } }
        guard connected == 0 else { return false }
        var local = sockaddr_in6()
        var length = size
        let named = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { return false }
        return isGlobal(withUnsafeBytes(of: local.sin6_addr) { Array($0) })
    }

    static func netdev(windows: Bool, macHasIPv6: Bool) -> String {
        windows && !macHasIPv6 ? "user,id=net0,ipv6=off" : "user,id=net0"
    }
}

/// When a machine's automatic backup is due, and which old ones go.
nonisolated enum BackupSchedule {
    static let folderKey = "AVMBackupFolder"
    static let keep = 3

    static func isDue(every: String?, last: Date?, now: Date) -> Bool {
        let period: TimeInterval
        switch every {
        case "daily": period = 86_400
        case "weekly": period = 7 * 86_400
        default: return false
        }
        guard let last else { return true }
        // An hour's grace: the look is hourly, and a daily backup shouldn't creep.
        return now.timeIntervalSince(last) >= period - 3600
    }

    /// A new backup's name: sorts by date, and never clashes within a minute.
    static func name(base: String, ext: String, date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HHmm"
        return "\(base) backup \(format.string(from: date)).\(ext)"
    }

    /// Of a folder's names, this machine's backups past the newest `keep`.
    static func oldOnes(in names: [String], base: String, ext: String, keep: Int = BackupSchedule.keep) -> [String] {
        let mine = names.filter { $0.hasPrefix("\(base) backup ") && $0.hasSuffix(".\(ext)") }.sorted()
        return Array(mine.dropLast(keep))
    }
}

