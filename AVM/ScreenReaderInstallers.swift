// ScreenReaderInstallers.swift
// AVM — Accessible Virtual Machine
//
// Gets the installers for the screen readers a Windows VM should have from
// its first sign-in (2026-10-26): NVDA, free and GPL, from NV Access; JAWS
// for ARM, from Freedom Scientific (Vispero). AVM never ships either one:
// it downloads each from its maker when the VM's install media is built.
// JAWS's license doesn't allow redistribution, and downloading fresh means
// every new VM gets the current version.
//
// WHICH VERSION, newest source first:
//   - NVDA: NV Access's own update feed, the one NVDA's built-in updater
//     reads, with the release's SHA-1. winget's manifests can lag a
//     release behind: a VM installed with NVDA 2026.2 asked to update to
//     2026.3 at its first sign-in (2026-10-26).
//   - Both: the newest release in winget's public package manifests
//     (github.com/microsoft/winget-pkgs), with its SHA-256.
//   - Both: the version pinned below, if neither can be read.
// Whichever it is:
//   - the link must be on the maker's own host (ScreenReader.vendorHost);
//     anything else is refused, so a bad feed can't point elsewhere;
//   - the file must match the published checksum before it is used.
// Downloads are kept in Application Support, so a second VM reuses them.
//
// JAWS without a license runs in 40-minute demo mode; activation can't be
// scripted, so the user activates it inside Windows with their own license.

import Foundation
import CryptoKit

nonisolated struct ScreenReaderInstaller: Sendable, Equatable {
    let reader: ScreenReader
    let version: String
    let url: URL
    let checksum: Checksum
}

/// A published checksum, uppercase hex. NV Access publishes SHA-1 (what
/// NVDA's own updater checks); winget and the pinned versions use SHA-256.
nonisolated enum Checksum: Sendable, Equatable {
    case sha256(String)
    case sha1(String)
}

nonisolated enum ScreenReaderInstallerError: LocalizedError, Sendable {
    case download(String)
    case checksum(String)

    var errorDescription: String? {
        switch self {
        case .download(let detail): return detail
        case .checksum(let name): return "The \(name) installer didn't match its published checksum, so AVM didn't use it."
        }
    }
}

nonisolated enum ScreenReaderInstallers {

    /// Used when winget's manifests can't be read. Each from the maker's
    /// own server, with winget's published SHA-256, as of 2026-10-26.
    static let pinned: [ScreenReader: ScreenReaderInstaller] = [
        .nvda: ScreenReaderInstaller(
            reader: .nvda, version: "2026.2",
            url: URL(string: "https://download.nvaccess.org/releases/2026.2/nvda_2026.2.exe")!,
            checksum: .sha256("F3F8D29974A88D687B3C4809BE192219EC579C5BDABCDA5AAF53635288BCA824")),
        .jaws: ScreenReaderInstaller(
            reader: .jaws, version: "2026.2609.84.400",
            url: URL(string: "https://software.vfo.digital/JAWS/2026/2026.2609.84.400/6824AC12-A96A-43F1-A5C5-D33CFC10B790/J2026.2609.84.400-Offline-arm64.exe")!,
            checksum: .sha256("C73C2A2A5A057CF0383E8409EF6AE1B00E8FB8B78B58036E4457DAAE095C73D5")),
    ]

    // MARK: Finding the newest version

    private static let api = "https://api.github.com/repos/microsoft/winget-pkgs/contents/"
    private static let raw = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/"

    private static let nvAccessFeed = "https://api.nvaccess.org/nvdaUpdateCheck?versionType=stable"

    /// The newest release: NV Access's feed (NVDA), then winget, then pinned.
    static func latest(_ reader: ScreenReader) async -> ScreenReaderInstaller {
        if reader == .nvda {
            do {
                let found = try nvAccessRelease(text: try await text(nvAccessFeed))
                if found.url.host == reader.vendorHost, found.url.scheme == "https" {
                    return found
                }
                AVMLog.write("AVM: ScreenReaders — NV Access's feed link isn't on \(reader.vendorHost); trying winget.")
            } catch {
                AVMLog.write("AVM: ScreenReaders — couldn't read NV Access's update feed (\(error.localizedDescription)); trying winget.")
            }
        }
        do {
            let found = try await lookUp(reader)
            guard found.url.host == reader.vendorHost, found.url.scheme == "https" else {
                AVMLog.write("AVM: ScreenReaders — winget's \(reader.displayName) link isn't on \(reader.vendorHost); using the pinned version.")
                return pinned[reader]!
            }
            return found
        } catch {
            AVMLog.write("AVM: ScreenReaders — couldn't read winget's \(reader.displayName) manifest (\(error.localizedDescription)); using the pinned version.")
            return pinned[reader]!
        }
    }

    private static func lookUp(_ reader: ScreenReader) async throws -> ScreenReaderInstaller {
        switch reader {
        case .nvda:
            let base = "manifests/n/NVAccess/NVDA"
            let version = try await newestFolder(base)
            let yaml = try await text(raw + "\(base)/\(version)/NVAccess.NVDA.installer.yaml")
            return try installer(reader, version: version, yaml: yaml, architecture: "x86")
        case .jaws:
            let base = "manifests/f/FreedomScientific/JAWS"
            let year = try await newestFolder(base)
            let version = try await newestFolder("\(base)/\(year)")
            let yaml = try await text(raw + "\(base)/\(year)/\(version)/FreedomScientific.JAWS.\(year).installer.yaml")
            return try installer(reader, version: version, yaml: yaml, architecture: "arm64")
        }
    }

    /// The highest numbered release folder (release candidates skipped).
    private static func newestFolder(_ path: String) async throws -> String {
        let data = try await fetch(api + path)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ScreenReaderInstallerError.download("winget's listing for \(path) wasn't readable")
        }
        let versions = entries.compactMap { $0["type"] as? String == "dir" ? $0["name"] as? String : nil }
            .filter { $0.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil }
        guard let newest = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else {
            throw ScreenReaderInstallerError.download("winget lists no release for \(path)")
        }
        return newest
    }

    /// NV Access's update feed: "key: value" lines, among them version,
    /// launcherUrl and launcherHash (SHA-1).
    static func nvAccessRelease(text: String) throws -> ScreenReaderInstaller {
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let version = fields["version"], !version.isEmpty,
              let link = fields["launcherUrl"].flatMap(URL.init(string:)),
              let hash = fields["launcherHash"],
              hash.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else {
            throw ScreenReaderInstallerError.download("NV Access's update feed didn't list a release")
        }
        return ScreenReaderInstaller(reader: .nvda, version: version, url: link, checksum: .sha1(hash.uppercased()))
    }

    /// InstallerUrl and InstallerSha256 of the entry for `architecture`.
    static func installer(_ reader: ScreenReader, version: String, yaml: String, architecture: String) throws -> ScreenReaderInstaller {
        var blocks: [[String: String]] = []
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                blocks.append([:])
            }
            let field = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            guard !blocks.isEmpty, let colon = field.firstIndex(of: ":") else { continue }
            let key = field[..<colon].trimmingCharacters(in: .whitespaces)
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            blocks[blocks.count - 1][key] = value
        }
        guard let block = blocks.first(where: { $0["Architecture"] == architecture }),
              let link = block["InstallerUrl"].flatMap(URL.init(string:)),
              let sha = block["InstallerSha256"], sha.count == 64 else {
            throw ScreenReaderInstallerError.download("winget's \(reader.displayName) manifest has no \(architecture) installer")
        }
        return ScreenReaderInstaller(reader: reader, version: version, url: link, checksum: .sha256(sha.uppercased()))
    }

    // MARK: Downloading

    /// Downloads (or reuses) each installer into `cache`, checked against
    /// its SHA-256. `say` gets the spoken progress. Returns what it got; a
    /// screen reader that fails is left out and its failure spoken, so the
    /// install goes ahead with the others and Narrator.
    static func fetchAll(_ readers: [ScreenReader], into cache: URL,
                         say: @escaping @Sendable (String, Bool) async -> Void) async -> [ScreenReader: URL] {
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var got: [ScreenReader: URL] = [:]
        for reader in readers {
            let installer = await latest(reader)
            let file = cache.appendingPathComponent("\(reader.rawValue)-\(installer.version).exe")
            if (try? matches(file, installer.checksum)) == true {
                AVMLog.write("AVM: ScreenReaders — reusing \(reader.displayName) \(installer.version).")
                got[reader] = file
                continue
            }
            await say("Downloading \(reader.displayName) \(installer.version) from its maker.", false)
            // Tries more than once (2026-10-27, a tester's NVDA: "The request
            // timed out" ended the only try, and Windows was installed with
            // Narrator alone). A stalled or dropped download is tried again.
            var lastError: Error?
            var resumeData: Data?
            for attempt in 1...downloadAttempts {
                do {
                    try await download(installer, to: file, resumeData: resumeData, say: say)
                    guard try matches(file, installer.checksum) else {
                        try? FileManager.default.removeItem(at: file)
                        throw ScreenReaderInstallerError.checksum(reader.displayName)
                    }
                    AVMLog.write("AVM: ScreenReaders — downloaded and checked \(reader.displayName) \(installer.version)\(attempt > 1 ? " on try \(attempt)" : "").")
                    got[reader] = file
                    removeOlderCopies(of: reader, keeping: file, in: cache)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    // A stopped download carries where it got to: the next
                    // try carries on from there (JAWS is 1.5 GB).
                    resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                    let ns = error as NSError
                    AVMLog.write("AVM: ScreenReaders — \(reader.displayName) try \(attempt) of \(downloadAttempts) failed from \(installer.url.host ?? "?"): \(error.localizedDescription) [\(ns.domain) \(ns.code)]\(resumeData != nil ? "; the next try carries on where it stopped" : "")")
                    try? FileManager.default.removeItem(at: file.appendingPathExtension("part"))
                    if attempt < downloadAttempts {
                        await say("\(reader.displayName)'s download stopped. Trying again.", false)
                        try? await Task.sleep(for: .seconds(5 * attempt))
                    }
                }
            }
            if let lastError {
                await say("\(reader.displayName) couldn't be downloaded after \(downloadAttempts) tries, so it won't be installed this time. Reason: \(lastError.localizedDescription) Windows still has Narrator: in Windows, press Control Command Return to turn it on, then install \(reader.displayName) from its maker's website there.", true)
            }
        }
        return got
    }

    /// A newer version replaces the saved one; JAWS alone is 1.5 GB.
    private static func removeOlderCopies(of reader: ScreenReader, keeping file: URL, in cache: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? []
        where name.hasPrefix("\(reader.rawValue)-") && name != file.lastPathComponent {
            let url = cache.appendingPathComponent(name)
            // A piece another download is writing is left alone for a day.
            if name.contains(".part"),
               let changed = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(changed) < 86_400 { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Tries per installer before giving up on it.
    static let downloadAttempts = 3

    /// Waits up to two minutes for more of an installer before a try gives
    /// up (the system's default is one), and allows a whole hour per try:
    /// JAWS is 1.5 GB.
    private static let downloads: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        // Not waiting for a connection (2026-10-28, fourth audit): offline,
        // each try waited out the hour in silence, three times, before the
        // Windows build even began. Offline now fails at once, and Windows
        // installs with Narrator.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// One try at an installer, written to disk by a download task.
    ///
    /// It used to read the download one byte at a time through
    /// URLSession.bytes (2026-10-27, MEASURED: about 100 KB/s with a whole
    /// CPU core busy, where the network gave 30 MB/s), so the reader, not the
    /// network, set the pace: a 69 MB NVDA took many minutes, the connection
    /// sat backed up until a server dropped it ("The request timed out"),
    /// and JAWS's 1.5 GB could hardly finish. A download task writes at the
    /// network's speed, and a stopped one hands back resume data
    /// (NSURLSessionDownloadTaskResumeData in the error) for the next try.
    private static func download(_ installer: ScreenReaderInstaller, to file: URL, resumeData: Data?,
                                 say: @escaping @Sendable (String, Bool) async -> Void) async throws {
        // Its own name per download (2026-10-28, code review): two machines
        // starting at once shared one, and one's move took the other's file.
        let part = file.appendingPathExtension("part-\(UUID().uuidString.prefix(8))")
        // Whatever happens, the piece doesn't stay (2026-10-28, second
        // review: a failed final move left 1.5 GB behind for good).
        defer { try? FileManager.default.removeItem(at: part) }
        let box = TaskBox()
        // Large downloads (JAWS is 1.5 GB) say how far they've got.
        let progress = Task {
            var lastTenth = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let task = box.task else { continue }
                let total = task.countOfBytesExpectedToReceive
                guard total > 100_000_000 else { continue }
                let tenth = Int(Double(task.countOfBytesReceived) / Double(total) * 10)
                if tenth > lastTenth, tenth < 10 {
                    lastTenth = tenth
                    await say("\(installer.reader.displayName) download \(tenth * 10) percent.", false)
                }
            }
        }
        defer { progress.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done: @Sendable (URL?, URLResponse?, Error?) -> Void = { location, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let location, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    continuation.resume(throwing: ScreenReaderInstallerError.download("\(installer.url.host ?? "the server") answered \(code)"))
                    return
                }
                // The temporary file goes when this returns: moved now.
                do {
                    try? FileManager.default.removeItem(at: part)
                    try FileManager.default.moveItem(at: location, to: part)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            let task = resumeData.map { downloads.downloadTask(withResumeData: $0, completionHandler: done) }
                ?? downloads.downloadTask(with: installer.url, completionHandler: done)
            box.task = task
            task.resume()
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: part, to: file)
    }

    /// The running download task, for the progress poll.
    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
    }

    static func matches(_ file: URL, _ checksum: Checksum) throws -> Bool {
        switch checksum {
        case .sha256(let expected): return try digest(of: file, SHA256()) == expected
        case .sha1(let expected): return try digest(of: file, Insecure.SHA1()) == expected
        }
    }

    static func sha256(of file: URL) throws -> String {
        try digest(of: file, SHA256())
    }

    private static func digest<H: HashFunction>(of file: URL, _ hasher: H) throws -> String {
        var hasher = hasher
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02X", $0) }.joined()
    }

    // MARK: Network

    private static func fetch(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw ScreenReaderInstallerError.download("bad address \(url)") }
        var request = URLRequest(url: u)
        request.setValue("AVM", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ScreenReaderInstallerError.download("\(u.host ?? "the server") answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    private static func text(_ url: String) async throws -> String {
        String(decoding: try await fetch(url), as: UTF8.self)
    }
}
