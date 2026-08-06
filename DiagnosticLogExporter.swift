// DiagnosticLogExporter.swift
// AVM — Accessible Virtual Machine
//
// STAGE D (2026-08-06): the "Save Diagnostic Log…" menu action. Gathers
// AVM's diagnostic files into one folder the user chooses, so "please send
// me the log" is a single deliverable a tester can inspect in Finder with
// VoiceOver BEFORE sending — being able to read what you are handing over
// is part of the privacy promise (see AVMLog's header), not incidental.
//
// WHAT THE BUNDLE CONTAINS:
//   - Every kept file log (avm-<timestamp>.log) from AVMLog's directory that
//     has at least one content line — current launch plus up to two rotated
//     predecessors. The interesting failure is often in the PREVIOUS
//     launch's file, which is why the rotated files ride along. Copied
//     as-is under their original names; they are sanitized at the write
//     choke point (AVMLog Promise 2), so no second pass is needed or wanted.
//   - firmware-serial.log from EVERY VM runtime dir that has a non-empty
//     one, renamed firmware-serial-<first 8 of VM UUID>.log. Copying all of
//     them instead of guessing "the most recent VM" removes a hidden
//     judgment call; they are tiny. Verified 2026-08-06 on a live sample
//     plus by construction: this file's only writer is the guest side of
//     the serial line (edk2/Windows Boot Manager), which never sees a host
//     path, so it is copied WITHOUT a sanitizer pass — the only identifiers
//     in it are guest-internal (GPT GUIDs) and the VM identity AVM itself
//     injects, which a diagnostic bundle SHOULD carry.
//   - Missing or empty sources are skipped silently: the tester cannot act
//     on an omission, and absence is visible to us on receipt (decision of
//     record, 2026-08-06).
//
// COPIES, NEVER MOVES. The originals stay exactly where they are.
//
// THE GATE: if nothing collectible exists — no file log with a content line
// past the header, no non-empty serial log — the action announces
// "There is no diagnostic log to save yet." (.info, NOT .failure: nothing is
// broken, there is simply nothing to send, and .failure's interrupt-and-
// flush right-of-way is reserved for actual failures) and no panel opens.
// "Empty" deliberately means "no content beyond the header": AVMLog writes
// a ~half-KB header at setup, and a header-only file is not worth sending.
//
// THE GATE-FAIL RECORD GOES TO NSLog, NOT THE FILE LOG — a deliberate,
// documented exception to the Stage C verdicts-to-file-log rule. Writing
// "nothing to save" into the file log would itself make the log non-empty,
// and the NEXT save request would pass the gate and bundle a log whose only
// content is the record of the previous empty attempt. The one verdict
// whose subject is the log's own emptiness cannot live in the log.
//
// LOAD-BEARING ORDER (do not reorder the calls in saveDiagnosticLog):
//   AVMLog's writer is a serial FIFO queue; AVMLog.write enqueues async and
//   AVMLog.currentLogURL() runs queue.sync. A sync call therefore cannot
//   return until every previously enqueued write has completed — and
//   FileHandle.write is an unbuffered syscall, so "completed" means
//   "on disk". currentLogURL() is used HERE as that barrier, twice:
//     1. Before the gate, so the gate reads a fully drained, fresh file
//        rather than racing queued writes.
//     2. After the "saving" verdict write and before the copy, so the
//        copied file provably contains the record of its own creation.
//   No sleeps, no flush API, no race — but only while the barrier calls
//   stay where they are.
//
// The "saving" verdict is written AFTER the user confirms the save panel,
// not when the panel opens: a "save requested" line followed by a cancel
// would read as an unfinished operation. Cancel is the user's own action
// and produces silence and no log line, per design.
//
// The current launch's log is copied while AVMLog's FileHandle remains open
// for writing. That is safe: writes are whole-line appends via an
// unbuffered syscall, so any snapshot of the file is line-consistent — the
// copy simply ends at whatever line was most recent, which the barrier
// guarantees includes the "saving" verdict.
//
// ANNOUNCEMENTS (scheme approved 2026-08-06):
//   success        -> .success  "Diagnostic log saved to <folder> in <place>."
//   nothing to save -> .info    "There is no diagnostic log to save yet."
//   copy failure   -> .failure  "Saving the diagnostic log failed. <reason>"

import AppKit
import Foundation

enum DiagnosticLogExporter {

    /// One file headed for the bundle: where it is now, and what it will be
    /// called inside the saved folder.
    private struct Source: Sendable {
        let url: URL
        let destinationName: String
    }

    // MARK: - Entry point

    /// Runs the full Save Diagnostic Log flow: gate, panel, copy, announce.
    /// Call from the main actor (menu action). Never throws; every outcome
    /// is announced or deliberately silent (cancel).
    @MainActor
    static func saveDiagnosticLog() async {
        // Barrier 1 (see LOAD-BEARING ORDER): drain any queued writes so the
        // gate reads current reality. Side effect: if nothing has logged yet
        // this launch, this creates the header-only file — which the gate
        // then correctly treats as empty.
        _ = AVMLog.currentLogURL()

        let sources = collectSources()

        guard sources.isEmpty == false else {
            // Deliberate exception to verdicts-to-file-log — see header.
            NSLog("AVM: Diagnostics — save requested; nothing to save yet (no log content, no serial logs).")
            Announcer.shared.announce("There is no diagnostic log to save yet.", tone: .info)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save Diagnostic Log"
        panel.nameFieldStringValue = defaultBundleName()
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.message = "AVM will create a folder with this name containing its diagnostic log files."

        guard panel.runModal() == .OK, let destination = panel.url else {
            return // Cancel: the user's own action — silence, no log line.
        }

        // The destination path may contain the user's home path; AVMLog's
        // sanitizer handles that at the write choke point, as always.
        AVMLog.write("Diagnostics — saving log bundle to \(destination.path).")

        // Barrier 2: the verdict above is on disk before the copy begins,
        // so the bundle records its own creation.
        _ = AVMLog.currentLogURL()

        do {
            let copied = try await Task.detached(priority: .userInitiated) {
                try performCopy(sources: sources, to: destination)
            }.value
            AVMLog.write("Diagnostics — log bundle saved: \(copied) file(s) in \(destination.lastPathComponent).")
            let place = destination.deletingLastPathComponent().lastPathComponent
            Announcer.shared.announce("Diagnostic log saved to \(destination.lastPathComponent) in \(place).", tone: .success)
        } catch {
            AVMLog.write("Diagnostics — FAILED to save log bundle: \(error.localizedDescription)")
            Announcer.shared.announce("Saving the diagnostic log failed. \(error.localizedDescription)", tone: .failure)
        }
    }

    // MARK: - Gathering

    /// Everything collectible right now: file logs with content, non-empty
    /// firmware serial logs. Empty result means the gate fails.
    private static func collectSources() -> [Source] {
        var sources: [Source] = []
        let fm = FileManager.default

        // File logs: everything matching AVMLog's naming in its directory.
        // Name sort = date sort (AVMLog's own prune relies on the same
        // property), oldest first so the bundle listing reads chronologically.
        if let dir = AVMLog.logDirectory,
           let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            let logs = names
                .filter { $0.hasPrefix("avm-") && $0.hasSuffix(".log") }
                .sorted()
            for name in logs {
                let url = dir.appendingPathComponent(name)
                if hasContentLine(url) {
                    sources.append(Source(url: url, destinationName: name))
                }
            }
        }

        // Firmware serial logs: one per VM runtime dir that has a non-empty
        // one. Same Application Support root AVMLog anchors to.
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let vmsDir = appSupport
                .appendingPathComponent("AVM", isDirectory: true)
                .appendingPathComponent("vms", isDirectory: true)
            if let entries = try? fm.contentsOfDirectory(at: vmsDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                // Sorted so bundle contents are deterministic run to run.
                for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let serial = entry.appendingPathComponent("firmware-serial.log")
                    guard let attrs = try? fm.attributesOfItem(atPath: serial.path),
                          let size = attrs[.size] as? Int, size > 0 else {
                        continue // Missing or empty: skipped silently, per design.
                    }
                    let shortID = String(entry.lastPathComponent.prefix(8))
                    sources.append(Source(url: serial,
                                          destinationName: "firmware-serial-\(shortID).log"))
                }
            }
        }

        return sources
    }

    /// True if the file has at least one timestamped log line — i.e. content
    /// beyond AVMLog's header. Reads only the first 4 KB: the header is
    /// well under 1 KB, so the first content line (if any exists) falls
    /// inside the window. The header's "Started <date>" line does not match
    /// because the pattern is anchored to line start and that line begins
    /// with the word "Started".
    private static func hasContentLine(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), data.isEmpty == false else { return false }
        // Lossy decode: a 4 KB cut can land mid–multibyte character, and a
        // strict decode would fail on the torn tail and misread real content
        // as absence. Lossy decoding never fails and the timestamp pattern
        // is pure ASCII.
        let text = String(decoding: data, as: UTF8.self)
        return text.range(of: #"(?m)^\d{4}-\d{2}-\d{2} \d{2}:"#, options: .regularExpression) != nil
    }

    // MARK: - Copying (off the main actor)

    /// Creates the bundle folder and copies every source into it. Runs on a
    /// detached task so a slow disk never blocks the main thread after the
    /// panel is dismissed. Throws on the first failure; the caller owns
    /// announcing it.
    private nonisolated static func performCopy(sources: [Source], to destination: URL) throws -> Int {
        let fm = FileManager.default
        // The save panel already asked the user about replacing an existing
        // item with this name; honoring that answer means actually replacing
        // it rather than failing on "file exists".
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var copied = 0
        for source in sources {
            try fm.copyItem(at: source.url,
                            to: destination.appendingPathComponent(source.destinationName))
            copied += 1
        }
        return copied
    }

    // MARK: - Naming

    /// "AVM Diagnostic Log 2026-08-06" — date-only, per the approved
    /// default; a same-day second save goes through the panel's standard
    /// replace prompt, which performCopy honors.
    private static func defaultBundleName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "AVM Diagnostic Log \(f.string(from: Date()))"
    }
}
