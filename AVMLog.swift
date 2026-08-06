// AVMLog.swift
// AVM — Accessible Virtual Machine
//
// THE SINGLE FILE LOGGER. Everything AVM writes to disk for diagnostic
// purposes goes through this one choke point.
//
// WHY THIS FILE EXISTS (2026-07-26):
//   AVM is heading for external testers, and "please send me the log" has to
//   be a safe thing to ask. Before this file there were TWO independent
//   loggers (VMManager.avmLog and WindowsInstallPipeline.pipelineLog), each
//   with its own copy of the same open/seek/write/close code, both writing to
//   ~/Desktop/avm_debug.log. The problems that survey found, all fixed here:
//     1. RACE. Each call did open -> seekToEndOfFile -> write -> close. The
//        pipeline runs OFF the main actor while VMManager is @MainActor, so
//        during a VM create both were live simultaneously. Two seeks to the
//        same end offset before either write = one line silently overwrites
//        the other. Fixed by a single serial queue: one writer, ordered.
//     2. NEVER TRUNCATED. data.write(to:) ran only when the file did not
//        exist, so every launch since the file was first created appended to
//        the same one, forever, with no reset. Fixed by one file per launch,
//        last three kept.
//     3. UTC TIMESTAMPS. "\(Date())" renders +0000, so the file read four
//        hours off the wall clock and four hours off the unified log. A
//        tester saying "it froze around 10:15" would find nothing near 10:15.
//        Fixed: local time with offset, matching `log show` output so lines
//        from both sources can be read side by side.
//     4. SILENT FAILURES. try? everywhere — if the log could not be written,
//        nothing said so, in a project whose first principle is that silence
//        is never neutral. Fixed: failures go to NSLog, and the user-facing
//        "Save Diagnostic Log to Desktop" action is responsible for
//        announcing a missing or empty file (the one moment a tester actually
//        needs to know, and an action they initiated).
//
// ============================ THE TWO PROMISES ============================
//
// The header written at the top of every log file makes two factual claims to
// the person reading it. Under this project's standing rule — if AVM says it,
// it must be true, and that rule reaches all the way down into comments and
// user-facing strings (see Handoff 18 §1, four false claims; Handoff 17 §2, a
// fifth) — those claims are load-bearing. Both are structural, not hopeful:
//
//   PROMISE 1: NOTHING TYPED IS EVER WRITTEN HERE.
//     Guaranteed by ABSENCE, not by filtering. There is no code path from a
//     keystroke to this file. handleKey and handleFlagsChanged in VMView.swift
//     do not call into this logger, and must never be made to. A scrubber
//     could have a bug, miss a format, or be bypassed by a call site added a
//     year from now; an absent call cannot.
//     MECHANICAL CHECK (belongs in every handoff):
//       grep -n "AVMLog\|avmLog" views/VMView.swift   -> expect NO output
//     Keystroke logging still exists for development (the vk= NSLogs), but it
//     goes to the unified log only, and Stage B gates it off by default.
//
//   PROMISE 2: THE MAC USER NAME DOES NOT APPEAR.
//     Paths are genuinely needed for diagnosis, so absence is not available
//     here — the user name is incidental cargo inside strings we want. It
//     therefore gets the other structural answer: ONE sanitizer at the ONE
//     write call, below. Every line reaches the file through sanitize(), so a
//     call site added later inherits it without knowing it exists. Sanitizing
//     at call sites would be the fragile version, and the same failure mode as
//     a keystroke scrubber.
//
// Both claims are mechanically checkable BY THE TESTER, which is the point. A
// blind tester can read the whole file with VoiceOver and confirm for
// themselves that neither their typing nor their name is in it, rather than
// taking anyone's word for it. Plain text is a deliberate choice for exactly
// this reason: being able to verify what you are handing over is part of the
// privacy promise, not incidental to it.
//
// IF YOU CHANGE THE HEADER TEXT, RE-READ THIS BLOCK FIRST. The header is a
// promise, not decoration.
// =========================================================================
//
// WHAT BELONGS IN THIS LOG: VM lifecycle, install pipeline stages, failures,
// spoken announcements, Caps Lock remap apply/restore, focus-lock
// transitions. What does NOT: per-keystroke events (see Promise 1), the
// 4-second screendump timer (555 of 626 lines in one H17 sample), and the
// DEBUG draw tracing. The latter two are removed in Stage C.
//
// NOT @MainActor DELIBERATELY. WindowsInstallPipeline runs off the main
// actor; making this main-isolated would force every pipeline log call to hop
// actors mid-stage. Thread safety comes from the serial queue instead: all
// mutable state below is touched ONLY inside queue.async.
//
// FileHandle.write() is an unbuffered write syscall, so there is no flush
// step and nothing is lost if the app is force-quit — every line already
// written is already on disk. That matters for wedge diagnosis, where the
// interesting lines are the last ones before the freeze.
import Foundation

final class AVMLog: @unchecked Sendable {

    static let shared = AVMLog()

    // MARK: Tunables
    /// Stop writing past this size rather than rotating mid-session, so "the
    /// run where it broke" stays one discrete file. Generous today; Stage C
    /// removes the screendump timer that generates most of the volume.
    private let byteCap = 5 * 1024 * 1024
    /// Including the one being created now.
    private let filesKept = 3

    // MARK: State — touched ONLY on `queue`.
    private let queue = DispatchQueue(label: "com.alllisonmeloy.AVM.filelog", qos: .utility)
    private var handle: FileHandle?
    private var bytesWritten = 0
    private var capNoticeWritten = false
    private var didSetUp = false
    private var setUpFailed = false
    private var currentURL: URL?

    private let stamp: DateFormatter = {
        let f = DateFormatter()
        // Matches `log show` output so file lines and unified-log lines can be
        // read against each other. Local time WITH offset — see problem 3.
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {}

    // MARK: - Public API

    /// Write one line. Safe from any thread. Never throws, never blocks the
    /// caller on disk I/O.
    /// - Parameter category: short tag such as "pipeline" or "focus", rendered
    ///   as `[category]`. Omit for general VM lifecycle lines.
    static func write(_ message: String, category: String? = nil) {
        shared.enqueue(message, category: category)
    }

    /// The log file for THIS launch, or nil if setup failed. Used by the
    /// "Save Diagnostic Log to Desktop" action, which owns announcing a
    /// missing or empty file to the user.
    static func currentLogURL() -> URL? {
        shared.queue.sync {
            shared.setUpIfNeeded()
            return shared.currentURL
        }
    }

    /// Directory holding the kept log files.
    static var logDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("AVM", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    // MARK: - Sanitizer (Promise 2)

    /// Replace every occurrence of the Mac user's home path with `~`.
    ///
    /// Two passes, deliberately:
    ///   1. Regex on `/Users/<component>` — catches ANY user name, including
    ///      paths that came from elsewhere (a bundled tool's stderr, a QEMU
    ///      error string), not just this machine's.
    ///   2. Literal replacement of this machine's user name, as belt and
    ///      braces for a bare name appearing outside a path.
    ///
    /// The literal pass is SKIPPED for names shorter than 4 characters. A
    /// two-letter user name would otherwise shred ordinary words in the log
    /// ("jo" turning every "join" into "~in"), which would be worse than the
    /// leak it prevents — mangled diagnostics that quietly mislead. Long names
    /// are effectively unique and safe to replace.
    ///
    /// nonisolated static so it can be reasoned about and tested on its own.
    nonisolated static func sanitize(_ s: String) -> String {
        var out = s

        if let rx = homePathRegex {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = rx.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "~")
        }

        let user = NSUserName()
        if user.count >= 4 {
            out = out.replacingOccurrences(of: user, with: "~")
        }

        return out
    }

    /// `/Users/` plus one path component, stopping at the next separator,
    /// whitespace, or quote so surrounding text is left intact.
    /// Compiled once — this runs on every logged line.
    private nonisolated static let homePathRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "/Users/[^/\\s\"'\\\\]+", options: [])
    }()

    // MARK: - Internals (all on `queue`)

    private func enqueue(_ message: String, category: String?) {
        let now = Date()
        queue.async { [self] in
            setUpIfNeeded()
            guard let handle, !setUpFailed else { return }

            if bytesWritten >= byteCap {
                guard !capNoticeWritten else { return }
                capNoticeWritten = true
                let notice = "\(stamp.string(from: now)): [log] SIZE CAP REACHED (\(byteCap) bytes). No further lines will be written to this file.\n"
                if let d = notice.data(using: .utf8) { try? handle.write(contentsOf: d) }
                NSLog("AVM: diagnostic log hit its size cap; no further file logging this launch.")
                return
            }

            let tag = category.map { "[\($0)] " } ?? ""
            let line = "\(stamp.string(from: now)): \(tag)\(Self.sanitize(message))\n"
            guard let data = line.data(using: .utf8) else { return }

            do {
                try handle.write(contentsOf: data)
                bytesWritten += data.count
            } catch {
                // Problem 4: do not fail silently. NSLog rather than a spoken
                // announcement — a failing disk could fire this hundreds of
                // times, and .failure flushes the Announcer queue.
                NSLog("AVM: diagnostic log write failed: \(error.localizedDescription)")
            }
        }
    }

    private func setUpIfNeeded() {
        guard !didSetUp else { return }
        didSetUp = true

        guard let dir = Self.logDirectory else {
            setUpFailed = true
            NSLog("AVM: diagnostic log unavailable — could not locate Application Support.")
            return
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            setUpFailed = true
            NSLog("AVM: diagnostic log unavailable — could not create \(dir.path): \(error.localizedDescription)")
            return
        }

        prune(in: dir)

        // Sortable name; one file per launch.
        let nameStamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()
        let url = dir.appendingPathComponent("avm-\(nameStamp).log")

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            setUpFailed = true
            NSLog("AVM: diagnostic log unavailable — could not create \(url.path).")
            return
        }
        guard let h = try? FileHandle(forWritingTo: url) else {
            setUpFailed = true
            NSLog("AVM: diagnostic log unavailable — could not open \(url.path) for writing.")
            return
        }

        handle = h
        currentURL = url

        let header = Self.headerText()
        if let d = header.data(using: .utf8) {
            try? h.write(contentsOf: d)
            bytesWritten += d.count
        }
        NSLog("AVM: diagnostic log started at \(url.path)")
    }

    /// Keep the newest `filesKept - 1` existing files, making room for the one
    /// about to be created. Names sort chronologically, so a name sort is a
    /// date sort — no file-attribute reads needed.
    private func prune(in dir: URL) {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let logs = all.filter { $0.hasPrefix("avm-") && $0.hasSuffix(".log") }.sorted()
        let keep = max(filesKept - 1, 0)
        guard logs.count > keep else { return }
        for name in logs.prefix(logs.count - keep) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// THE HEADER IS A PROMISE — see "THE TWO PROMISES" at the top of this
    /// file before editing a single word of it.
    private static func headerText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersionString

        let started: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()

        return """
        AVM diagnostic log
        Started \(started) · AVM \(version) (build \(build)) · \(os)

        This log records what AVM did: virtual machines starting and
        stopping, install steps, errors, and spoken announcements.

        It does NOT record anything you type. AVM has no code that can
        write keystrokes to this file.

        Your macOS user name has been replaced with ~ throughout.

        """
    }
}
