// LinuxISODownload.swift
// AVM — Accessible Virtual Machine
//
// The setup wizard's "Download Linux…" (2026-10-30, the user's request: to
// get Windows and Linux from the wizard; Windows already has its sheet,
// ISODownloadView). Ubuntu, Debian and Fedora publish their installers
// openly, so AVM downloads the one chosen itself, from the distribution's
// own server:
//   - It finds the current file in the release's folder (the newest point
//     release, 26.04.1 rather than 26.04), so nothing here goes stale with
//     each one.
//   - It says how far along it is every 10 percent, and on request.
//   - It checks the file against the SHA-256 list the distribution
//     publishes beside it, and a mismatch is never offered.
//   - It saves into Downloads, and a copy already there that checks out is
//     used as it is.
//   - It picks the file as the new machine's installer.
// The releases are the ones AVM's unattended installs are proven on:
// Ubuntu 26.04, Debian's current stable and Fedora 44.

import SwiftUI
import AppKit
import CryptoKit
import Combine

// MARK: - The downloader

@MainActor
final class LinuxISODownloader: NSObject, ObservableObject {

    enum Distribution: String, CaseIterable, Identifiable {
        case ubuntu, debian, fedora

        var id: Self { self }

        var title: String {
            switch self {
            case .ubuntu: return "Ubuntu Desktop"
            case .debian: return "Debian"
            case .fedora: return "Fedora"
            }
        }

        /// For the list: what it is, and how big.
        var detail: String {
            switch self {
            case .ubuntu: return "Ubuntu 26.04, the whole desktop on the installer: about 4 gigabytes."
            case .debian: return "Debian's current release, a small installer that downloads the desktop while it installs: about 700 megabytes."
            case .fedora: return "Fedora 44 Workstation, a small installer that downloads the desktop while it installs: about 1.2 gigabytes."
            }
        }

        var folder: URL {
            switch self {
            case .ubuntu: return URL(string: "https://cdimage.ubuntu.com/releases/26.04/release/")!
            case .debian: return URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/")!
            case .fedora: return URL(string: "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/aarch64/iso/")!
            }
        }

        /// The installer's file name in the folder's listing.
        var filePattern: String {
            switch self {
            case .ubuntu: return #"ubuntu-26\.04(\.\d+)?-desktop-arm64\.iso"#
            case .debian: return #"debian-\d+\.\d+\.\d+-arm64-netinst\.iso"#
            case .fedora: return #"Fedora-Everything-netinst-aarch64-44-[\d.]+\.iso"#
            }
        }

        /// The list of SHA-256 sums in the same folder.
        var checksumPattern: String {
            switch self {
            case .ubuntu, .debian: return #"SHA256SUMS"#
            case .fedora: return #"Fedora-Everything-44-[\d.]+-aarch64-CHECKSUM"#
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case finding
        case downloading
        case verifying
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var distribution: Distribution = .ubuntu
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    /// Picks the checked file as the installer: set by the setup wizard,
    /// so a download that ends with this window closed picks itself too.
    var onReady: ((URL) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var fileName = ""
    private var expectedHash = ""
    private var lastTenth = 0

    var isBusy: Bool {
        switch phase {
        case .finding, .downloading, .verifying: return true
        default: return false
        }
    }

    var spokenProgress: String {
        switch phase {
        case .finding: return "Finding \(distribution.title)'s current installer."
        case .downloading:
            guard expected > 0 else { return "\(distribution.title): \(Self.size(received)) so far." }
            return "\(distribution.title): \(Int(Double(received) / Double(expected) * 100)) percent, \(Self.size(received)) of \(Self.size(expected))."
        case .verifying: return "Checking \(distribution.title)'s installer against its published checksum."
        case .finished(let url): return "Ready: \(url.lastPathComponent)."
        case .failed(let message): return message
        case .idle: return ""
        }
    }

    static func size(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb >= 1 ? String(format: "%.1f gigabytes", gb) : "\(Int((Double(bytes) / 1_000_000).rounded())) megabytes"
    }

    // MARK: Starting and stopping

    func start(_ chosen: Distribution) {
        guard !isBusy else { return }
        distribution = chosen
        received = 0
        expected = 0
        lastTenth = 0
        phase = .finding
        Announcer.shared.announce("Finding \(chosen.title)'s current installer.", tone: .info)
        Task {
            do {
                try await find()
            } catch {
                fail("AVM couldn't find \(chosen.title)'s installer. Reason: \(error.localizedDescription) Check the Mac's internet connection, then try again.")
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        phase = .idle
        Announcer.shared.announce("The \(distribution.title) download is cancelled.", tone: .info)
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        AVMLog.write("Linux download: \(message)")
        Announcer.shared.announce(message, tone: .failure)
    }

    // MARK: Finding the file and its checksum

    private func find() async throws {
        let folder = distribution.folder
        let listing = try await Self.text(at: folder)
        let names = Self.matches(distribution.filePattern, in: listing)
        guard let name = names.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Its folder lists no installer."])
        }
        guard let sumsName = Self.matches(distribution.checksumPattern, in: listing).max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Its folder lists no checksums."])
        }
        let sums = try await Self.text(at: folder.appendingPathComponent(sumsName))
        guard let hash = Self.hash(of: name, in: sums) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Its checksum list has no line for \(name)."])
        }
        fileName = name
        expectedHash = hash
        let destination = Self.downloads.appendingPathComponent(name)
        // One already downloaded is used, once it checks out.
        if FileManager.default.fileExists(atPath: destination.path) {
            AVMLog.write("Linux download: \(name) is in Downloads already; checking it")
            await verify(destination, alreadyThere: true)
            return
        }
        AVMLog.write("Linux download: \(folder.appendingPathComponent(name).absoluteString)")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: folder.appendingPathComponent(name))
        self.task = task
        phase = .downloading
        Announcer.shared.announce("Downloading \(name) from \(folder.host ?? "its maker"). AVM says how far along it is every 10 percent.", tone: .info)
        task.resume()
    }

    private static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    private static func text(at url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(url.host ?? "The server") answered \(http.statusCode)."])
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Array(Set(regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }))
    }

    /// The SHA-256 for `name`, from either form a distribution publishes:
    /// "hash  name" or "hash *name" (Debian, Ubuntu), or "SHA256 (name) =
    /// hash" (Fedora).
    static func hash(of name: String, in sums: String) -> String? {
        for line in sums.split(separator: "\n").map(String.init) where line.contains(name) {
            let hex = matches("[0-9a-fA-F]{64}", in: line)
            if let first = hex.first { return first.lowercased() }
        }
        return nil
    }

    // MARK: Progress and the finished file

    fileprivate func progressed(_ bytes: Int64, of total: Int64) {
        received = bytes
        expected = total
        guard total > 0 else { return }
        let tenth = Int(Double(bytes) / Double(total) * 10)
        if tenth > lastTenth, tenth < 10 {
            lastTenth = tenth
            Announcer.shared.announce(spokenProgress, tone: .info)
        }
    }

    fileprivate func downloaded(to temporary: URL?, error: String?) {
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
        guard phase == .downloading else { return }   // cancelled meanwhile
        guard let temporary else {
            fail("The \(distribution.title) download stopped. Reason: \(error ?? "unknown") Try again.")
            return
        }
        let destination = Self.downloads.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            fail("AVM couldn't put the download in Downloads. Reason: \(error.localizedDescription)")
            return
        }
        Task { await verify(destination, alreadyThere: false) }
    }

    private func verify(_ file: URL, alreadyThere: Bool) async {
        phase = .verifying
        Announcer.shared.announce(spokenProgress, tone: .info)
        let expectedHash = self.expectedHash
        let actual = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        guard actual == expectedHash else {
            if alreadyThere {
                // An old or broken copy: downloaded afresh in its place.
                AVMLog.write("Linux download: the copy in Downloads didn't match; downloading it again")
                try? FileManager.default.removeItem(at: file)
                phase = .finding
                Task {
                    do { try await find() } catch { fail("AVM couldn't download \(distribution.title). Reason: \(error.localizedDescription)") }
                }
            } else {
                try? FileManager.default.removeItem(at: file)
                fail("\(file.lastPathComponent) didn't match the checksum \(distribution.title) publishes, so AVM deleted it. Try the download again.")
            }
            return
        }
        phase = .finished(file)
        AVMLog.write("Linux download: \(file.lastPathComponent) checked against its published SHA-256")
        Announcer.shared.announce("\(distribution.title) is downloaded and checked: \(file.lastPathComponent), in Downloads. It's chosen as the installer.", tone: .success)
        onReady?(file)
    }
}

extension LinuxISODownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in self.progressed(totalBytesWritten, of: totalBytesExpectedToWrite) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Moved before returning: the system deletes its file after.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iso")
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        Task { @MainActor in
            if moved, (200..<300).contains(status) {
                self.downloaded(to: kept, error: nil)
            } else {
                try? FileManager.default.removeItem(at: kept)
                self.downloaded(to: nil, error: moved ? "the server answered \(status)." : "the downloaded file couldn't be kept.")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let message = error.localizedDescription
        Task { @MainActor in self.downloaded(to: nil, error: message) }
    }
}

// MARK: - The sheet

/// "Download Linux": the distribution to get, how it's going, and the
/// buttons for each stage. Same rules as the Windows sheet: a heading to
/// land on, Escape and Command-Return for the main buttons.
struct LinuxDownloadView: View {
    @ObservedObject var downloader: LinuxISODownloader
    @State private var choice: LinuxISODownloader.Distribution = .ubuntu
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Download Linux")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Text("AVM downloads the installer from the distribution's own server, says how far along it is every 10 percent, checks it against the checksum the distribution publishes, and chooses it as the installer. It's saved in Downloads.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Distribution to download", selection: $choice) {
                ForEach(LinuxISODownloader.Distribution.allCases) { distribution in
                    Text(distribution.title).tag(distribution)
                }
            }
            .pickerStyle(.radioGroup)
            // Named once, by its title, with the shown label hidden: an
            // accessibilityLabel was added to the title, not put in its place.
            .labelsHidden()
            .disabled(downloader.isBusy)
            Text(choice.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            status

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(28)
        .frame(minWidth: 480)
    }

    @ViewBuilder
    private var status: some View {
        switch downloader.phase {
        case .idle:
            EmptyView()
        case .finding, .downloading, .verifying:
            HStack(spacing: 10) {
                if downloader.phase == .downloading, downloader.expected > 0 {
                    ProgressView(value: Double(downloader.received), total: Double(downloader.expected))
                        .frame(width: 160)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(downloader.spokenProgress)
            }
            .accessibilityElement(children: .combine)
            Button("Speak Progress") {
                Announcer.shared.announce(downloader.spokenProgress, tone: .info)
            }
            .keyboardShortcut("p", modifiers: .command)
            .accessibilityHint("Says how far along the download is. Command P.")
        case .finished(let url):
            Text("Ready, and chosen as the installer: \(url.lastPathComponent)")
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Error: \(message)")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch downloader.phase {
        case .idle, .failed:
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Download \(choice.title)") { downloader.start(choice) }
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityHint("Downloads the installer, checks it, and chooses it. Command Return.")
        case .finding, .downloading, .verifying:
            Button("Cancel Download") { downloader.cancel() }
                .accessibilityHint("Stops the download. Nothing is kept.")
            Button("Keep Downloading in Background") {
                Announcer.shared.announce("AVM keeps downloading \(downloader.distribution.title), says how far along it is every 10 percent, and chooses it as the installer when it's checked.", tone: .info)
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityHint("Closes this window. The download goes on, and the installer is chosen when it's ready. Escape.")
        case .finished:
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
    }
}

/// The download with no window (2026-10-30), for a full system test of a
/// Linux install the way a user gets it:
///
///   AVM.app/Contents/MacOS/AVM --download-linux ubuntu|debian|fedora
///
/// It runs LinuxISODownloader exactly as the setup wizard's Download Linux
/// does, printing each step, and exits 0 with the installer's path as its
/// last line, or 1 with the reason.
@MainActor
enum LinuxDownloadJob {
    static let flag = "--download-linux"

    /// Called first thing at launch; returns only when not asked.
    static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: flag) else { return }
        AVMLog.useTestLogFolder()
        Announcer.isMuted = true
        guard arguments.indices.contains(i + 1),
              let distribution = LinuxISODownloader.Distribution(rawValue: arguments[i + 1]) else {
            print("Usage: AVM \(flag) ubuntu|debian|fedora")
            exit(64)
        }
        let downloader = LinuxISODownloader()
        var said = ""
        var tenth = -1
        downloader.start(distribution)
        while true {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            switch downloader.phase {
            case .finished(let url):
                print(url.path)
                exit(0)
            case .failed(let message):
                print("FAILED: \(message)")
                exit(1)
            case .downloading where downloader.expected > 0:
                let now = Int(Double(downloader.received) / Double(downloader.expected) * 10)
                if now != tenth { tenth = now; print(downloader.spokenProgress) }
            default:
                if downloader.spokenProgress != said {
                    said = downloader.spokenProgress
                    print(said)
                }
            }
            fflush(stdout)
        }
    }
}
