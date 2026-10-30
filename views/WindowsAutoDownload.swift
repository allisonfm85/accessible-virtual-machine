// WindowsAutoDownload.swift
// AVM — Accessible Virtual Machine
//
// Windows 11 for ARM with no website to touch (2026-10-30, the user's
// request: a blind user should get Windows without ever handling a web
// page). Microsoft's download page sits behind bot checks, and AVM doesn't
// try to get around them (WindowsISODownloader keeps that path, in the
// browser). This takes the channel Microsoft's own Media Creation Tool
// uses instead:
//   - Its public catalog, products.cab (go.microsoft.com/fwlink/?LinkId=
//     2156292), lists every Windows 11 download with a direct link on
//     Microsoft's servers (dl.delivery.mp.microsoft.com) and a SHA-1. AVM
//     reads it (macOS's tar opens the cabinet) and picks ARM64, in the Mac's
//     language, English if Microsoft has none.
//   - It downloads that file, an .esd of about 4.5 GB, saying how far along
//     it is every 10 percent, and checks its SHA-1.
//   - An .esd isn't an ISO, so AVM makes one, with the wimlib-imagex it
//     bundles for the install pipeline: image 1 is the setup files, 2 and 3
//     Windows Setup's boot.wim, and the rest the editions (Home, Home Single
//     Language, Pro), exported as install.wim, the name the pipeline reads.
//   - The ISO is UDF, as Microsoft's own are (hdiutil makehybrid): the
//     pipeline reads it through a macOS mount, and macOS's ISO 9660 reader
//     sees only the first 4 GB of a larger file (tested), so an xorriso ISO
//     gave a cut-off install.wim. It boots through Microsoft's own EFI image
//     (efi/microsoft/boot/efisys.bin), which the pipeline takes from there
//     when it rebuilds the install media.
//   - It saves the ISO in Downloads, deletes the .esd and the work folder,
//     and picks the ISO as the installer.

import SwiftUI
import AppKit
import CryptoKit
import Combine

@MainActor
final class WindowsAutoDownloader: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle
        case finding
        case downloading
        case verifying
        case building(String)
        case finished(URL)
        case failed(String)
    }

    /// One download in Microsoft's catalog.
    struct Offer: Equatable {
        let fileName: String
        let url: URL
        let sha1: String
        let size: Int64
        let language: String
        let languageCode: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published private(set) var offer: Offer?
    /// Picks the finished ISO as the installer, set by the setup wizard, so
    /// one that finishes with this window closed picks itself too.
    var onReady: ((URL) -> Void)?

    static let catalogURL = URL(string: "https://go.microsoft.com/fwlink/?LinkId=2156292")!
    /// What it needs free: the .esd, the unpacked files and the ISO.
    static let spaceNeeded: Int64 = 20_000_000_000

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var lastTenth = 0
    private var work: URL?

    var isBusy: Bool {
        switch phase {
        case .finding, .downloading, .verifying, .building: return true
        default: return false
        }
    }

    var spokenProgress: String {
        switch phase {
        case .idle: return ""
        case .finding: return "Finding Windows 11 for ARM in Microsoft's catalog."
        case .downloading:
            guard expected > 0 else { return "Windows: \(LinuxISODownloader.size(received)) so far." }
            return "Windows: \(Int(Double(received) / Double(expected) * 100)) percent, \(LinuxISODownloader.size(received)) of \(LinuxISODownloader.size(expected))."
        case .verifying: return "Checking the download against Microsoft's checksum."
        case .building(let step): return step
        case .finished(let url): return "Ready: \(url.lastPathComponent)."
        case .failed(let message): return message
        }
    }

    // MARK: Starting and stopping

    func start() {
        guard !isBusy else { return }
        received = 0
        expected = 0
        lastTenth = 0
        phase = .finding
        Announcer.shared.announce(spokenProgress, tone: .info)
        Task {
            do {
                try await find()
            } catch {
                fail("AVM couldn't get Windows from Microsoft. Reason: \(error.localizedDescription) Check the Mac's internet connection, then try again.")
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        cleanUp()
        phase = .idle
        Announcer.shared.announce("The Windows download is cancelled.", tone: .info)
    }

    private func fail(_ message: String) {
        cleanUp()
        phase = .failed(message)
        AVMLog.write("Windows download: \(message)")
        Announcer.shared.announce(message, tone: .failure)
    }

    private func cleanUp() {
        if let work { try? FileManager.default.removeItem(at: work) }
        work = nil
    }

    private static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    // MARK: Microsoft's catalog

    private func find() async throws {
        let space = (try? Self.downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard space >= Self.spaceNeeded else {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSLocalizedDescriptionKey:
                "It needs about 20 gigabytes free on the Mac while it works, and there are \(LinuxISODownloader.size(space))."])
        }
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: Self.downloads, create: true)
        self.work = work
        let (cab, _) = try await URLSession.shared.download(from: Self.catalogURL)
        let cabFile = work.appendingPathComponent("products.cab")
        try FileManager.default.moveItem(at: cab, to: cabFile)
        // macOS's tar (libarchive) opens Microsoft's cabinet files.
        try await Self.run("/usr/bin/tar", ["-xf", cabFile.path, "-C", work.path])
        let xml = try Data(contentsOf: work.appendingPathComponent("products.xml"))
        guard let chosen = Self.choose(from: xml, language: Self.macLanguageCode) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Microsoft's catalog has no Windows 11 for ARM in it."])
        }
        offer = chosen
        AVMLog.write("Windows download: \(chosen.fileName), \(chosen.language), from \(chosen.url.absoluteString)")
        // Plain http, as the catalog gives it (2026-10-30, the full
        // system test): Microsoft's download host has no certificate of its
        // own over https, so Info.plist lets this one host through App
        // Transport Security. The SHA-1 from the catalog, which comes over
        // https, checks what arrives.
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: chosen.url)
        self.task = task
        phase = .downloading
        Announcer.shared.announce("Downloading Windows 11 for ARM, \(chosen.language), from Microsoft: \(LinuxISODownloader.size(chosen.size)). AVM says how far along it is every 10 percent.", tone: .info)
        task.resume()
    }

    /// The Mac's language as Microsoft writes it: "en-us", "fr-fr".
    static var macLanguageCode: String {
        let locale = Locale.current
        let language = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? "US"
        return "\(language)-\(region)".lowercased()
    }

    /// The consumer Windows 11 ARM64 download in `language` from the
    /// catalog, or in the same language for another region, or English.
    static func choose(from xml: Data, language: String) -> Offer? {
        guard let document = try? XMLDocument(data: xml),
              let files = try? document.nodes(forXPath: "//File") else { return nil }
        var offers: [Offer] = []
        for case let file as XMLElement in files {
            func value(_ name: String) -> String { file.elements(forName: name).first?.stringValue ?? "" }
            guard value("Architecture").uppercased() == "ARM64", value("Edition") == "Professional",
                  let url = URL(string: value("FilePath")), !value("Sha1").isEmpty else { continue }
            offers.append(Offer(fileName: value("FileName"), url: url, sha1: value("Sha1").lowercased(),
                                size: Int64(value("Size")) ?? 0, language: value("Language"),
                                languageCode: value("LanguageCode").lowercased()))
        }
        let base = language.split(separator: "-").first.map(String.init) ?? language
        return offers.first { $0.languageCode == language }
            ?? offers.first { $0.languageCode.hasPrefix(base + "-") }
            ?? offers.first { $0.languageCode == "en-us" }
    }

    // MARK: Progress, the check and the ISO

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
        guard let temporary, let work, let offer else {
            fail("The Windows download stopped. Reason: \(error ?? "unknown") Try again.")
            return
        }
        let esd = work.appendingPathComponent(offer.fileName)
        do {
            try FileManager.default.moveItem(at: temporary, to: esd)
        } catch {
            fail("AVM couldn't keep the download. Reason: \(error.localizedDescription)")
            return
        }
        Task { await verifyAndBuild(esd, offer: offer, work: work) }
    }

    private func verifyAndBuild(_ esd: URL, offer: Offer, work: URL) async {
        phase = .verifying
        Announcer.shared.announce(spokenProgress, tone: .info)
        let sha1 = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let handle = try? FileHandle(forReadingFrom: esd) else { return nil }
            defer { try? handle.close() }
            var hasher = Insecure.SHA1()
            while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        guard sha1 == offer.sha1 else {
            fail("The download didn't match Microsoft's checksum, so AVM deleted it. Try again.")
            return
        }
        do {
            let iso = try await build(from: esd, offer: offer, work: work)
            cleanUp()
            phase = .finished(iso)
            AVMLog.write("Windows download: \(iso.lastPathComponent) made from \(offer.fileName)")
            Announcer.shared.announce("Windows 11 for ARM is ready: \(iso.lastPathComponent), in Downloads. It's chosen as the installer.", tone: .success)
            onReady?(iso)
        } catch {
            fail("AVM couldn't make the Windows installer. Reason: \(error.localizedDescription)")
        }
    }

    /// The .esd made into an ISO the install pipeline reads like Microsoft's.
    private func build(from esd: URL, offer: Offer, work: URL) async throws -> URL {
        guard let resources = Bundle.main.resourcePath else { throw CocoaError(.fileNoSuchFile) }
        let wimlib = URL(fileURLWithPath: resources).appendingPathComponent("wimlib-imagex").path
        let tree = work.appendingPathComponent("tree")
        let sources = tree.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        func step(_ words: String) {
            phase = .building(words)
            Announcer.shared.announce(words, tone: .info)
        }
        step("Making the Windows installer: unpacking Windows Setup.")
        try await Self.run(wimlib, ["apply", esd.path, "1", tree.path])
        step("Making the Windows installer: its startup image.")
        try await Self.run(wimlib, ["export", esd.path, "2", sources.appendingPathComponent("boot.wim").path, "--compress=LZX"])
        try await Self.run(wimlib, ["export", esd.path, "3", sources.appendingPathComponent("boot.wim").path, "--boot"])
        // The editions: every image after the three of Setup.
        let info = try await Self.run(wimlib, ["info", esd.path])
        let count = info.split(separator: "\n").first { $0.hasPrefix("Image Count:") }
            .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 3
        guard count > 3 else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The download has no editions of Windows in it."]) }
        for index in 4...count {
            step("Making the Windows installer: edition \(index - 3) of \(count - 3). This takes a few minutes.")
            try await Self.run(wimlib, ["export", esd.path, "\(index)", sources.appendingPathComponent("install.wim").path, "--compress=LZX"])
        }
        step("Making the Windows installer: the disc image.")
        let label = "CCCOMA_A64FRE_\(offer.languageCode.uppercased())_DV9"
        let iso = Self.freeName(in: Self.downloads, "Windows 11 ARM64 \(offer.languageCode).iso")
        try await Self.run("/usr/bin/hdiutil", ["makehybrid", "-o", iso.path, tree.path, "-udf", "-iso", "-joliet",
                                                 "-udf-volume-name", label, "-iso-volume-name", label, "-joliet-volume-name", label,
                                                 "-eltorito-boot", tree.appendingPathComponent("efi/microsoft/boot/efisys.bin").path,
                                                 "-no-emul-boot"])
        return iso
    }

    private static func freeName(in folder: URL, _ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(number).iso")
            number += 1
        }
        return url
    }

    /// A tool run off the main thread; its output, or an error with its end.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                AVMLog.write("Windows download: \((tool as NSString).lastPathComponent) failed (\(process.terminationStatus)): \(output.suffix(600))")
                throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey:
                    "\((tool as NSString).lastPathComponent) stopped with \(process.terminationStatus)."])
            }
            return output
        }.value
    }
}

extension WindowsAutoDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in self.progressed(totalBytesWritten, of: totalBytesExpectedToWrite) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Moved before returning: the system deletes its file after.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".esd")
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        Task { @MainActor in
            if moved, (200..<300).contains(status) {
                self.downloaded(to: kept, error: nil)
            } else {
                try? FileManager.default.removeItem(at: kept)
                self.downloaded(to: nil, error: moved ? "Microsoft's server answered \(status)." : "the downloaded file couldn't be kept.")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let message = error.localizedDescription
        Task { @MainActor in self.downloaded(to: nil, error: message) }
    }
}

/// The download with no window (2026-10-30), for a full system test of the
/// Windows install the way a user gets it:
///
///   AVM.app/Contents/MacOS/AVM --download-windows
///
/// It runs WindowsAutoDownloader exactly as the setup wizard's Download
/// Windows 11 does, printing each step, and exits 0 with the ISO's path as
/// its last line, or 1 with the reason.
@MainActor
enum WindowsDownloadJob {
    static let flag = "--download-windows"

    /// Called first thing at launch; returns only when not asked.
    static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(flag) else { return }
        AVMLog.useTestLogFolder()
        Announcer.isMuted = true
        let downloader = WindowsAutoDownloader()
        var said = ""
        var tenth = -1
        downloader.start()
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
