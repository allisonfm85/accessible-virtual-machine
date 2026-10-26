// WindowsISODownloader.swift
// AVM — Accessible Virtual Machine
//
// The Windows ISO download assistant (2026-10-25, roadmap item 9). The
// download itself happens on Microsoft's own page, in the user's browser:
// that page sits behind Microsoft's bot checks, and AVM does not try to
// get around them. Everything around that step is AVM's:
//   - It opens Microsoft's Windows 11 for ARM page (the tester guide's
//     section 2 walks through it).
//   - It watches the folder the browser saves into (Downloads, unless the
//     user picks another) and speaks the download's progress every
//     gigabyte, because a browser's own progress is easy to lose track of
//     with a screen reader over 30 to 90 minutes.
//   - When an ISO arrives and stops growing, it checks the file: the ISO
//     9660 signature, a sensible size, and its SHA-256 against the table
//     Microsoft publishes on that page, which also tells AVM the language.
//   - It offers the file as the new VM's installer.
// The page is read with a plain request only for its checksum table. If
// that fails, the check falls back to size and format, and says so.

import Foundation
import Combine
import CryptoKit
import AppKit

@MainActor
final class WindowsISODownloader: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// The page is open and AVM is watching the folder.
        case watching
        /// A download is growing in the folder.
        case downloading
        case verifying
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var folder: URL
    @Published private(set) var bytesSoFar: Int64 = 0

    static let pageURL = URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!

    /// Microsoft's published SHA-256 per language label ("English",
    /// "English International"), read from the page. Empty if unread.
    private var publishedHashes: [String: String] = [:]
    /// Files already in the watched folders when watching began, by path,
    /// with what they were then; never mistaken for the new download. By
    /// identity, not name (2026-10-26): Microsoft's file name is the same
    /// every time, and a fresh download replacing an earlier one with that
    /// name used to be ignored.
    private var existing: [String: FileIdentity] = [:]
    /// The last thing logged per path, so the log says what was seen.
    private var logged: Set<String> = []
    private var watchTask: Task<Void, Never>?
    private var lastSpokenGB = 0

    /// A Windows 11 ARM ISO is about 8 GB; anything under 3 GB isn't one.
    private static let minimumISOSize: Int64 = 3_000_000_000

    init() {
        folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    func setFolder(_ url: URL) {
        folder = url
        if phase == .watching { snapshotExisting() }
    }

    // MARK: Start

    /// Opens Microsoft's page and starts watching the folder.
    func start() {
        stopped = false
        snapshotExisting()
        lastSpokenGB = 0
        bytesSoFar = 0
        phase = .watching
        NSWorkspace.shared.open(Self.pageURL)
        AVMLog.write("ISOAssistant: opened Microsoft's page; watching \(watchedFolders.map(\.path).joined(separator: ", "))")
        Announcer.shared.announce(
            "Microsoft's download page is open in your browser. Choose Windows 11 multi-edition ISO for Arm64, then your language, then the 64-bit download. Section 2 of the tester guide walks through the page. AVM is watching \(folder.lastPathComponent) and tells you how the download is going.",
            tone: .info
        )
        Task { await loadPublishedHashes() }
        watchTask?.cancel()
        watchTask = Task { await watch() }
    }

    /// Set by stop(): a check still running when the window closed ends
    /// quietly, rather than name a Use This Installer button that's gone
    /// (2026-10-25, code audit).
    private var stopped = false

    func stop() {
        stopped = true
        watchTask?.cancel()
        watchTask = nil
        if phase == .watching || phase == .downloading { phase = .idle }
    }

    /// "About 3 of 8 gigabytes downloaded so far." For the button and the
    /// once-a-gigabyte announcements.
    var spokenProgress: String {
        switch phase {
        case .idle: return "Not watching for a download."
        case .watching: return "Waiting for the download to start in \(folder.lastPathComponent)."
        case .downloading:
            let gb = Double(bytesSoFar) / 1_000_000_000
            return gb < 1
                ? "The download has started."
                : "About \(Int(gb)) of 8 gigabytes downloaded so far."
        case .verifying: return "Checking the downloaded file."
        case .finished(let url): return "Downloaded: \(url.lastPathComponent)."
        case .failed(let message): return message
        }
    }

    // MARK: Watching

    /// The chosen folder first, then the usual places a browser saves to
    /// (2026-10-26): a browser set to save somewhere else was never seen.
    private var watchedFolders: [URL] {
        let fm = FileManager.default
        var folders = [folder]
        for place in [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory] {
            if let url = fm.urls(for: place, in: .userDomainMask).first,
               !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                folders.append(url)
            }
        }
        return folders
    }

    struct FileIdentity: Equatable {
        let inode: UInt64
        let modified: Date?
    }

    private static func identity(of url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileIdentity(inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                            modified: attributes[.modificationDate] as? Date)
    }

    private func snapshotExisting() {
        existing = [:]
        logged = []
        for dir in watchedFolders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let url = dir.appendingPathComponent(name)
                if let id = Self.identity(of: url) { existing[url.path] = id }
            }
        }
    }

    /// Polls every two seconds. A finished ISO is one that has not grown
    /// for ten seconds and has no partial-download file beside it.
    private func watch() async {
        var stableSince: Date? = nil
        var lastSize: Int64 = -1
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let candidates = newEntries()
            let partial = candidates.first { Self.isPartial($0) }
            // An ISO named for ARM64 first, so an unrelated ISO that lands in
            // the folder isn't taken for Windows (2026-10-25, code audit).
            let isos = candidates.filter { $0.pathExtension.lowercased() == "iso" }
            let iso = isos.first { $0.lastPathComponent.lowercased().contains("arm64") } ?? isos.first

            if let partial {
                report(size: Self.size(of: partial))
                stableSince = nil
                continue
            }
            guard let iso else { continue }
            let size = Self.size(of: iso)
            report(size: size)
            if size == lastSize, size >= Self.minimumISOSize {
                if stableSince == nil { stableSince = Date() }
                if let since = stableSince, Date().timeIntervalSince(since) >= 10 {
                    await verify(iso)
                    return
                }
            } else {
                stableSince = nil
            }
            lastSize = size
        }
    }

    /// Files that weren't there when watching began, or have changed since:
    /// a new inode (replaced) or a new modification date (rewritten).
    private func newEntries() -> [URL] {
        var found: [URL] = []
        for dir in watchedFolders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name)
                guard Self.isPartial(url) || url.pathExtension.lowercased() == "iso" else { continue }
                if let before = existing[url.path], before == Self.identity(of: url) { continue }
                if !logged.contains(url.path) {
                    logged.insert(url.path)
                    AVMLog.write("ISOAssistant: saw \(Self.isPartial(url) ? "a download in progress" : "an ISO"): \(url.path)")
                }
                found.append(url)
            }
        }
        return found
    }

    /// Chrome .crdownload, Firefox .part, Safari .download (a bundle).
    private static func isPartial(_ url: URL) -> Bool {
        ["crdownload", "part", "download"].contains(url.pathExtension.lowercased())
    }

    /// Bytes on disk; for Safari's .download bundle, the largest file in it.
    private static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if isDirectory.boolValue {
            let inner = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            return inner.map { size(of: url.appendingPathComponent($0)) }.max() ?? 0
        }
        return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func report(size: Int64) {
        if phase == .watching {
            phase = .downloading
            Announcer.shared.announce("The download has started. AVM tells you every gigabyte.", tone: .info)
        }
        bytesSoFar = size
        let gb = Int(size / 1_000_000_000)
        if gb > lastSpokenGB {
            lastSpokenGB = gb
            Announcer.shared.announce(spokenProgress, tone: .info)
        }
    }

    // MARK: Verifying

    private func verify(_ iso: URL) async {
        AVMLog.write("ISOAssistant: \(iso.lastPathComponent) stopped growing; checking it")
        phase = .verifying
        Announcer.shared.announce("The download has finished. Checking the file. This takes about a minute.", tone: .info)
        let hashes = publishedHashes
        do {
            let (verdict, logLine) = try await Task.detached(priority: .userInitiated) { () throws -> (String, String) in
                let handle = try FileHandle(forReadingFrom: iso)
                defer { try? handle.close() }
                try handle.seek(toOffset: 32769)
                guard handle.readData(ofLength: 5) == Data("CD001".utf8) else {
                    throw AssistantError("\(iso.lastPathComponent) is not an ISO disc image. Next: download it again from Microsoft's page.")
                }
                try handle.seek(toOffset: 0)
                var hasher = SHA256()
                while true {
                    let chunk = try handle.read(upToCount: 8 * 1024 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
                let digest = hasher.finalize().map { String(format: "%02X", $0) }.joined()
                if let language = hashes.first(where: { $0.value == digest })?.key {
                    return ("It matches Microsoft's published checksum for the \(language) download.",
                            "ISOAssistant: SHA-256 matches the published \(language) value")
                }
                if hashes.isEmpty {
                    return ("AVM couldn't read Microsoft's checksum list, so it checked that the file is a whole ISO.",
                            "ISOAssistant: no published hashes; ISO signature checked; SHA-256 \(digest)")
                }
                return ("It is a whole ISO, but it doesn't match a checksum on Microsoft's page. That can happen just after Microsoft updates the download, or it may be a different file. When the machine first starts, AVM checks that it is a Windows 11 for ARM installer.",
                        "ISOAssistant: SHA-256 \(digest) matches no published value")
            }.value
            AVMLog.write(logLine)
            guard !stopped else {
                AVMLog.write("ISOAssistant: window closed during the check; not announcing")
                return
            }
            phase = .finished(iso)
            Announcer.shared.announce("\(iso.lastPathComponent) is ready. \(verdict) Choose Use This Installer.", tone: .success)
        } catch {
            guard !stopped else { return }
            let message = (error as? AssistantError)?.message ?? "AVM couldn't read the downloaded file: \(error.localizedDescription)"
            phase = .failed(message)
            AVMLog.write("ISOAssistant: \(message)")
            Announcer.shared.announce(message, tone: .failure)
        }
    }

    /// Reads the checksum table from Microsoft's page with a plain request.
    private func loadPublishedHashes() async {
        do {
            let (data, _) = try await URLSession(configuration: .ephemeral).data(from: Self.pageURL)
            let html = String(decoding: data, as: UTF8.self)
            var found: [String: String] = [:]
            let rows = try NSRegularExpression(pattern: #"<td>([^<]+?) 64-bit</td>\s*<td>([0-9A-Fa-f]{64})</td>"#)
            for match in rows.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                if let label = Range(match.range(at: 1), in: html), let hash = Range(match.range(at: 2), in: html) {
                    found[String(html[label])] = html[hash].uppercased()
                }
            }
            publishedHashes = found
            AVMLog.write("ISOAssistant: read \(found.count) published checksums")
        } catch {
            AVMLog.write("ISOAssistant: couldn't read Microsoft's page for checksums: \(error.localizedDescription)")
        }
    }
}

nonisolated struct AssistantError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}
