// MacAutoSetup.swift
// AVM — Accessible Virtual Machine
//
// Setup Assistant done for the user (2026-10-30, the user's request): a
// new macOS machine was the one install a blind user met without help,
// since AVM's answer files cover Windows and Linux and macOS has none. With
// "Set up macOS for me" in New macOS Virtual Machine, the first start goes
// through Setup Assistant by itself and leaves a signed-in Mac, with
// VoiceOver on when chosen.
//
// How: macOS machines ignore keys a program sends to their window (tried
// 2026-10-26), but Virtualization has a screen-sharing (VNC) server of its
// own for a machine (_VZVNCServer, not public, as other VM tools use it).
// AVM turns it on for setup only, with a random password, signs in with
// RFBClient, and then, screen by screen, reads the screen (ScreenText, as
// Read Screen does) and acts on what it says rather than on a fixed list
// of keys, so a new macOS that adds or moves a screen still gets through:
//   - the account screen: the name and password from the setup answers;
//   - any other: the first button found of Get Started, Set Up Later,
//     Not Now, Don't Use, Skip, Agree, Continue, Done, so optional
//     extras (Apple Account, Siri, Screen Time, location) are declined;
//   - a screen with no button text (the greeting, the language list):
//     Return.
// It ends at the desktop (the Finder's menu bar), or after a screen that
// doesn't change, which it reads aloud, so the user can finish by hand.
// The answers (with the password) are in the machine's folder, readable
// only by the user, and deleted when setup ends either way.

import Foundation
import ImageIO
import Virtualization

struct MacSetupAnswers: Codable, Equatable {
    var fullName: String
    var accountName: String
    var password: String
    var voiceOver: Bool

    /// The short account name macOS would make from a full name.
    static func accountName(for fullName: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let name = String(fullName.lowercased().filter { allowed.contains($0) })
        return name.isEmpty ? "user" : String(name.prefix(20))
    }
}

extension MacGuestFiles {
    var setupAnswers: URL { folder.appendingPathComponent("mac-setup.json") }
}

/// The parts of _VZVNCServer automatic setup uses, by their Objective-C
/// names (checked on macOS 27.2: initWithPort:queue:securityConfiguration:
/// takes an unsigned short port; port reads it back once listening).
@objc private protocol VNCServerSPI: NSObjectProtocol {
    init(port: UInt16, queue: DispatchQueue, securityConfiguration: AnyObject)
    var port: UInt16 { get }
    func setVirtualMachine(_ machine: VZVirtualMachine?)
    func start()
    func stop()
}

@objc private protocol VNCPasswordSPI: NSObjectProtocol {
    init(password: String)
}

@MainActor
enum MacAutoSetup {

    // MARK: The answers

    static func save(_ answers: MacSetupAnswers, files: MacGuestFiles) throws {
        let data = try JSONEncoder().encode(answers)
        try data.write(to: files.setupAnswers, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.setupAnswers.path)
    }

    static func answers(in files: MacGuestFiles) -> MacSetupAnswers? {
        guard let data = try? Data(contentsOf: files.setupAnswers) else { return nil }
        return try? JSONDecoder().decode(MacSetupAnswers.self, from: data)
    }

    static var isAvailable: Bool {
        NSClassFromString("_VZVNCServer") != nil && NSClassFromString("_VZVNCAuthenticationSecurityConfiguration") != nil
    }

    // MARK: Running it

    /// Goes through Setup Assistant on a machine just started. `say` is
    /// for progress the user hears. True when it reached the desktop.
    static func run(machine: VZVirtualMachine, files: MacGuestFiles, answers: MacSetupAnswers,
                    say: @escaping @MainActor (String) -> Void) async -> Bool {
        defer { try? FileManager.default.removeItem(at: files.setupAnswers) }
        guard isAvailable,
              let serverClass = NSClassFromString("_VZVNCServer"),
              let passwordClass = NSClassFromString("_VZVNCAuthenticationSecurityConfiguration") else {
            say("This Mac's Virtualization can't set macOS up automatically. Finish Setup Assistant yourself: give macOS the keyboard, wait on its first screen, and press Escape when it offers VoiceOver.")
            return false
        }
        let vncPassword = String((0..<8).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! })
        let security = unsafeBitCast(passwordClass, to: VNCPasswordSPI.Type.self).init(password: vncPassword)
        let server = unsafeBitCast(serverClass, to: VNCServerSPI.Type.self)
            .init(port: 0, queue: .main, securityConfiguration: security)
        server.setVirtualMachine(machine)
        server.start()
        defer { server.stop() }
        var port: UInt16 = 0
        for _ in 0..<50 where port == 0 {
            try? await Task.sleep(for: .milliseconds(100))
            port = server.port
        }
        guard port != 0 else {
            say("Automatic setup couldn't reach the machine's screen. Finish Setup Assistant yourself.")
            return false
        }
        AVMLog.write("AVM: MacAutoSetup — screen sharing on for setup (port \(port)).")
        say("Setting up macOS for you. This takes a few minutes; AVM says when it's done.")
        let outcome = await Task.detached(priority: .userInitiated) {
            await work(port: port, password: vncPassword, answers: answers, say: say)
        }.value
        switch outcome {
        case .done:
            AVMLog.write("AVM: MacAutoSetup — reached the desktop.")
            say(answers.voiceOver ? "macOS is set up and signed in as \(answers.fullName), with VoiceOver on." : "macOS is set up and signed in as \(answers.fullName).")
            return true
        case .stuck(let screen):
            AVMLog.write("AVM: MacAutoSetup — stopped on a screen that didn't change.")
            say("Automatic setup stopped on a screen it couldn't get past. It says: \(screen). Finish Setup Assistant yourself from here.")
            return false
        case .failed(let reason):
            AVMLog.write("AVM: MacAutoSetup — failed: \(reason)")
            say("Automatic setup stopped. Reason: \(reason) Finish Setup Assistant yourself from here.")
            return false
        }
    }

    enum Outcome: Sendable {
        case done
        case stuck(String)
        case failed(String)
    }

    /// Buttons pressed when seen, most wanted first.
    nonisolated static let buttons = ["Get Started", "Set Up Later", "Not Now", "Don't Use", "Skip", "Agree",
                                      // The Apple Account screen's menu, which has Set Up Later (sixth test run).
                                      "Other Sign-In Options", "Continue", "Done"]

    /// What to do with one screen's lines.
    enum Step: Equatable {
        case desktop
        case account
        case click(String, x: Int, y: Int)
        /// An option, then the screen's button for it.
        case choose(String, x: Int, y: Int, then: String, x2: Int, y2: Int)
        case returnKey
    }

    /// The line that is exactly `label`. With more than one, the one
    /// nearest the middle of the screen: a confirmation box's button over
    /// the dimmed one at the bottom of the page behind it (eighth test run,
    /// Terms and Conditions' second Agree).
    nonisolated private static func find(_ label: String, in lines: [ScreenText.Line]) -> ScreenText.Line? {
        let matches = lines.filter { normalized($0.text).caseInsensitiveCompare(label) == .orderedSame }
        guard matches.count > 1 else { return matches.first }
        let right = lines.map(\.frame.maxX).max() ?? 0
        let bottom = lines.map(\.frame.maxY).max() ?? 0
        let middle = CGPoint(x: right / 2, y: bottom / 2)
        return matches.min { a, b in
            hypot(a.frame.midX - middle.x, a.frame.midY - middle.y) < hypot(b.frame.midX - middle.x, b.frame.midY - middle.y)
        }
    }

    /// A button's words without a menu's chevron, which text recognition
    /// reads as a "v" ("Other Sign-In Options v", sixth test run).
    nonisolated static func normalized(_ text: String) -> String {
        var words = text.trimmingCharacters(in: .whitespaces)
        for tail in [" v", " V", " ⌄", " >", " ›"] where words.hasSuffix(tail) {
            words = String(words.dropLast(tail.count))
        }
        return words.trimmingCharacters(in: .whitespaces)
    }

    /// A screen's text without the clock, so a minute going by isn't a
    /// change of screen (first test runs, 2026-10-30).
    nonisolated static func withoutClock(_ text: String) -> String {
        text.replacingOccurrences(of: #"\b\d{1,2}:\d{2}\s?[AP]M\b"#, with: "", options: .regularExpression)
    }

    nonisolated static func step(for lines: [ScreenText.Line], height: Int) -> Step {
        let texts = lines.map { $0.text.trimmingCharacters(in: .whitespaces) }
        // The desktop: the Finder's menu bar along the top.
        let top = lines.filter { $0.frame.minY < CGFloat(height) * 0.06 }.map(\.text)
        if top.contains(where: { $0 == "Finder" }) && top.contains(where: { $0 == "Go" || $0 == "Window" }) {
            return .desktop
        }
        let all = texts.joined(separator: " ").lowercased()
        if all.contains("create a mac account") || all.contains("create your mac account") || all.contains("create a computer account") {
            return .account
        }
        // Transfer Your Data: a new Mac, not a migration (first test run:
        // Continue with the first choice left on started Migration
        // Assistant's search, which Not Now didn't leave).
        // Age Range (macOS 27, ninth test run): Adult, a row with no
        // Continue under it.
        if all.contains("age range"), let adult = find("Adult", in: lines) {
            return .click("Adult", x: Int(adult.frame.midX), y: Int(adult.frame.midY))
        }
        // The round button left of the words, not the words (third test
        // run: a click on the words left the first choice on).
        if all.contains("transfer your data"), let fresh = find("Set up as new", in: lines), let go = find("Continue", in: lines) {
            return .choose("Set up as new", x: Int(fresh.frame.minX - fresh.frame.height), y: Int(fresh.frame.midY),
                           then: "Continue", x2: Int(go.frame.midX), y2: Int(go.frame.midY))
        }
        for button in buttons {
            // The lowest match: buttons sit at the bottom, and a heading
            // or a sentence can hold the same words.
            if let line = find(button, in: lines) {
                return .click(button, x: Int(line.frame.midX), y: Int(line.frame.midY))
            }
        }
        return .returnKey
    }

    /// The screen-sharing key the Mac takes as Command: each candidate
    /// with Space, until Spotlight opens (then Escape closes it).
    /// Its own connection for each try, waiting 5 seconds: a key that does
    /// nothing changes nothing, and then no picture comes (eleventh test run).
    nonisolated static func findCommandKey(port: UInt16, password: String) -> UInt32? {
        for candidate in RFBClient.commandCandidates {
            guard let client = try? RFBClient(port: port, password: password, wait: 5) else { continue }
            _ = try? client.screen()   // the current picture, so the next is a change
            guard (try? client.press(RFBClient.space, with: [candidate])) != nil else { continue }
            usleep(1_500_000)
            guard let image = try? client.screen() else { continue }
            let text = (ScreenText.lines(in: image) ?? []).map(\.text).joined(separator: " ").lowercased()
            if text.contains("spotlight") || text.contains("search") {
                try? client.press(RFBClient.escape)
                usleep(500_000)
                return candidate
            }
        }
        return nil
    }

    nonisolated private static func work(port: UInt16, password: String, answers: MacSetupAnswers,
                                         say: @escaping @MainActor (String) -> Void) async -> Outcome {
        var client: RFBClient
        var reconnects = 0
        do {
            client = try RFBClient(port: port, password: password)
        } catch {
            return .failed(error.localizedDescription)
        }
        let started = Date()
        var lastText = ""
        var sameCount = 0
        var accountTries = 0
        // Past "Welcome to Mac", Setup Assistant's last screen: then a
        // screen with no button of its own is the desktop (tenth test run:
        // macOS 27 hides the menu bar there, so the Finder's isn't seen).
        var welcomed = false
        // Each screen as a picture with its text, for a test run to look
        // at (AVM_SETUP_PICTURES, set by Tools/test-macos-machine.sh).
        let pictures = ProcessInfo.processInfo.environment["AVM_SETUP_PICTURES"].map { URL(fileURLWithPath: $0) }
        var pictureNumber = 0
        while Date().timeIntervalSince(started) < 25 * 60 {
            try? await Task.sleep(for: .seconds(4))
            let image: CGImage
            do {
                image = try client.screen()
            } catch {
                // Quiet a while, as while macOS makes the account (third
                // test run): signed in again, up to five times.
                reconnects += 1
                guard reconnects <= 5 else { return .failed(error.localizedDescription) }
                AVMLog.write("AVM: MacAutoSetup — screen sharing went quiet (\(error.localizedDescription)); connecting again.")
                try? await Task.sleep(for: .seconds(5))
                guard let again = try? RFBClient(port: port, password: password) else { continue }
                client = again
                continue
            }
            reconnects = 0
            guard let lines = ScreenText.lines(in: image) else { continue }
            let text = withoutClock(lines.map(\.text).joined(separator: " "))
            // Nothing on screen yet (the machine still starting).
            if lines.isEmpty, Date().timeIntervalSince(started) < 8 * 60 { continue }
            if text == lastText { sameCount += 1 } else { sameCount = 0; lastText = text }
            // Busy, not stuck: macOS making the account, or setting up.
            if text.lowercased().contains("creating account") || text.lowercased().contains("setting up your mac") {
                sameCount = 0
                continue
            }
            if sameCount >= 8 { return .stuck(lines.prefix(8).map(\.text).joined(separator: ". ")) }
            var step = step(for: lines, height: image.height)
            if welcomed, step == .returnKey { step = .desktop }
            if case .click("Get Started", _, _) = step, text.lowercased().contains("welcome") { welcomed = true }
            AVMLog.write("AVM: MacAutoSetup — screen \"\(lines.first?.text ?? "")\": \(step)")
            if let pictures, sameCount == 0 {
                pictureNumber += 1
                let base = pictures.appendingPathComponent(String(format: "%03d", pictureNumber))
                if let destination = CGImageDestinationCreateWithURL(base.appendingPathExtension("png") as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                }
                try? (lines.map(\.text).joined(separator: "\n") + "\n=> \(step)\n").write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            }
            do {
                switch step {
                case .desktop:
                    if answers.voiceOver {
                        try? await Task.sleep(for: .seconds(3))
                        if let command = findCommandKey(port: port, password: password) {
                            // A fresh connection, and never fatal: setup is done.
                            if let fresh = try? RFBClient(port: port, password: password, wait: 5) {
                                try? fresh.press(RFBClient.f5, with: [command])
                            }
                            AVMLog.write("AVM: MacAutoSetup — Command is keysym \(String(command, radix: 16)); Command-F5 sent for VoiceOver.")
                        } else {
                            AVMLog.write("AVM: MacAutoSetup — no key came through as Command; VoiceOver not turned on.")
                            await say("macOS is set up, but AVM couldn't turn on its VoiceOver. Press Command-F5 inside the machine.")
                        }
                    }
                    return .done
                case .account:
                    // The screen opens with Full Name ready to type in;
                    // Account Name follows from it, then the password twice.
                    // Once: typed again, it went on the end of what was
                    // there (first test run, 2026-10-30). After that, Return,
                    // the screen's Continue.
                    // macOS making it: wait (seventh test run: it takes a
                    // while, and the unchanged screen was called stuck).
                    if text.lowercased().contains("creating account") {
                        sameCount = 0
                        continue
                    }
                    accountTries += 1
                    guard accountTries == 1 else {
                        if accountTries > 12 { return .stuck(lines.prefix(10).map(\.text).joined(separator: ". ")) }
                        // Continue again only now and then: an error under a
                        // field shows on the screen's text.
                        if accountTries % 4 == 0, let go = find("Continue", in: lines) {
                            try client.click(x: Int(go.frame.midX), y: Int(go.frame.midY))
                        }
                        continue
                    }
                    await say("Making your account, \(answers.fullName).")
                    // Each field clicked by its own placeholder (fourth test
                    // run: the screen opens with the picture chooser
                    // focused, not Full Name, and the typing went nowhere).
                    func field(_ label: String, _ text: String, replacing: Bool = false) throws {
                        guard let line = find(label, in: lines) else { return }
                        try client.click(x: Int(line.frame.midX), y: Int(line.frame.midY))
                        // Emptied with Backspace, not Command-A (fifth test
                        // run: Command didn't come through, and the "a" was
                        // typed into the name). The end first.
                        if replacing {
                            try client.press(0xff57)   // End
                            for _ in 0..<40 { try client.press(RFBClient.backspace) }
                        }
                        try client.type(text)
                    }
                    try field("Full Name", answers.fullName)
                    // Account Name fills itself in from the full name.
                    try await Task.sleep(for: .milliseconds(800))
                    try field("Account Name", answers.accountName, replacing: true)
                    try field("Password", answers.password)
                    try field("Verify Password", answers.password)
                    if let go = find("Continue", in: lines) {
                        try client.click(x: Int(go.frame.midX), y: Int(go.frame.midY))
                    } else {
                        try client.press(RFBClient.returnKey)
                    }
                case .choose(_, let x, let y, _, let x2, let y2):
                    try client.click(x: x, y: y)
                    try await Task.sleep(for: .milliseconds(600))
                    try client.click(x: x2, y: y2)
                case .click(_, let x, let y):
                    // A click that didn't move things on: Return, its default.
                    if sameCount >= 3 { try client.press(RFBClient.returnKey) } else { try client.click(x: x, y: y) }
                case .returnKey:
                    try client.press(sameCount % 2 == 0 ? RFBClient.returnKey : RFBClient.space)
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return .stuck(lastText)
    }
}
