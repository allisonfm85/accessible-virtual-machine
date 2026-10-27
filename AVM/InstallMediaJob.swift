// InstallMediaJob.swift
// AVM — Accessible Virtual Machine
//
// A window-less way to build a Windows machine's install media
// (2026-10-26), for Tools/test-windows-install.sh:
//
//   AVM.app/Contents/MacOS/AVM --build-install-media --iso <Windows ISO>
//       --out <folder> [--edition pro|home|homeSingleLanguage]
//       [--screen-readers nvda,jaws] [--guest windows|ubuntu|debian]
//
// For Ubuntu or Debian, <folder> must hold the account as the wizard
// writes it (ubuntu-account.json); Tools/test-linux-install.sh does that.
//
// It runs the same ensureInstallMedia a real first start runs, into
// <folder>, with the setup answers found there (windows-setup.json, as the
// wizard writes it), then exits: 0 with install-avm.iso and autounattend.img
// in <folder>, 1 with the reason on standard output. It makes no virtual
// machine, opens no window and starts nothing. Without the flag it does
// nothing at all.

import Foundation

@MainActor
enum InstallMediaJob {

    static let flag = "--build-install-media"

    /// Called first thing at launch; returns only when not asked.
    static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(flag) else { return }
        func value(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard let iso = value("--iso"), let out = value("--out") else {
            print("Usage: AVM \(flag) --iso <Windows ISO> --out <folder> [--edition pro|home|homeSingleLanguage] [--screen-readers nvda,jaws]")
            exit(64)
        }
        let edition = value("--edition") ?? WindowsEdition.pro.rawValue
        guard WindowsEdition(rawValue: edition) != nil else {
            print("Unknown edition \(edition).")
            exit(64)
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let guest = GuestOS(rawValue: value("--guest") ?? "windows") ?? .windows
        guard guest != .macOS else {
            print("macOS machines are made with New macOS Virtual Machine, not from an ISO.")
            exit(64)
        }
        var configuration = VMConfiguration(name: "Install test", installISOPath: iso,
                                            guestOSName: guest == .windows ? nil : guest.rawValue,
                                            windowsEditionName: guest == .windows ? edition : nil)
        configuration.windowsScreenReaderNames = value("--screen-readers")?
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

        final class Outcome { var code: Int32? }
        let outcome = Outcome()
        Task { @MainActor in
            do {
                try await VMManager().buildInstallMedia(configuration: configuration, into: folder)
                print("Install media ready in \(folder.path)")
                outcome.code = 0
            } catch {
                print("FAILED: \(error.localizedDescription)")
                outcome.code = 1
            }
        }
        // The app's run loop hasn't started yet; this one serves the job's
        // main-actor work until it is done.
        while outcome.code == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        exit(outcome.code ?? 1)
    }
}
