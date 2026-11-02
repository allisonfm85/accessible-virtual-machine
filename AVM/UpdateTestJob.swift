// UpdateTestJob.swift
// AVM — Accessible Virtual Machine
//
// An update really installing (2026-11-01, the user's request): nothing
// tested it, and a broken update is the worst thing to find after a launch,
// as it can stop people getting the fix. Tools/test-update.sh makes a copy of
// the app that calls itself very old, and this job runs in that copy:
//
//   AVM.app/Contents/MacOS/AVM --test-update [--feed <url>]
//
// Sparkle, with AVM's own feed by default, finds the newest release, downloads
// it, checks its signature and installs it over the copy. It's Sparkle's own
// install path, with this driver saying yes in place of the person. It doesn't
// relaunch: the new copy would start the user's machines.

import AppKit
import Sparkle

@MainActor
enum UpdateTestJob {

    static let flag = "--test-update"
    private static var driver: Driver?
    private static var delegate: Delegate?
    private static var updater: SPUUpdater?

    static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(flag) else { return }
        AVMLog.useTestLogFolder()
        let feed = arguments.firstIndex(of: "--feed").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        Task { @MainActor in
            let driver = Driver()
            let delegate = Delegate(feed: feed)
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
            self.driver = driver
            self.delegate = delegate
            self.updater = updater
            do {
                try updater.start()
            } catch {
                print("   NO   Sparkle started: \(error.localizedDescription)")
                print("FAILED"); exit(1)
            }
            print("   yes  Sparkle started")
            fflush(stdout)
            updater.checkForUpdates()
            // A slow network isn't a failure; this long is.
            try? await Task.sleep(for: .seconds(1200))
            print("   NO   the update finished within 20 minutes")
            print("FAILED"); exit(1)
        }
    }

    private final class Delegate: NSObject, SPUUpdaterDelegate {
        let feed: String?
        init(feed: String?) { self.feed = feed }
        func feedURLString(for updater: SPUUpdater) -> String? { feed }
        func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { false }
    }

    /// Everything Sparkle would ask a person, answered yes.
    private final class Driver: NSObject, SPUUserDriver {
        private func say(_ line: String) { print("   \(line)"); fflush(stdout) }
        private func failed(_ line: String) -> Never { print("   NO   \(line)"); print("FAILED"); fflush(stdout); exit(1) }

        func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
        }
        func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
        func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
            say("yes  it found \(appcastItem.displayVersionString) (\(appcastItem.versionString))")
            reply(.install)
        }
        func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
        func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
        func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
            failed("an update was found: \(error.localizedDescription)")
        }
        func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
            failed("the update went through: \(error.localizedDescription)")
        }
        func showDownloadInitiated(cancellation: @escaping () -> Void) { say("downloading") }
        func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
        func showDownloadDidReceiveData(ofLength length: UInt64) {}
        func showDownloadDidStartExtractingUpdate() { say("yes  downloaded; unpacking") }
        func showExtractionReceivedProgress(_ progress: Double) {}
        func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
            say("yes  its signature checked; installing")
            reply(.install)
            // With no relaunch, Sparkle installs when this copy quits, as it
            // does when a person quits later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        }
        func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        }
        func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
        func showUpdateInFocus() {}
        func dismissUpdateInstallation() {}
    }
}
