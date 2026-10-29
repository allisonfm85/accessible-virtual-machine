//
//  Announcer.swift
//  AVM
//
//  Created by Allison Meloy on 7/12/26.
//


// Announcer.swift
// AVM — Accessible Virtual Machine
//
// Interrupting, non-visual announcements for events the user must not miss
// (pipeline failure/completion, unexpected VM death). Motivated by the
// 2026-07-11 wrong-ISO incident: the pipeline's validation gate failed in
// under a second with exactly the right message — but nothing ANNOUNCED it,
// and half an hour passed before the failure was discovered by reading the
// debug log. A sighted user would have glanced and seen it; announcements are
// the non-visual glance.
//
// DESIGN — sound + synthesized speech, both unconditional:
//   - Sound first (NSSound): Glass for success, Basso for failure, Tink for
//     neutral state changes — the verdict reaches the ears before the speech
//     does, and works even if speech is interrupted or missed.
//   - Then the SYSTEM VOICE speaks the message via AVSpeechSynthesizer —
//     deliberately the same mechanism as the Terminal `alert`/`say` pattern
//     that is already the proven background-completion channel in this
//     project's workflow. Speech synthesis needs NO permission, plays
//     regardless of which app is frontmost, and is independent of VoiceOver.
//
// INTERRUPTION POLICY (revised 2026-07-24 — the eaten-announcement bug):
//   Originally EVERY announcement stopped any speech in progress. On the
//   first healthy-speed install, "Install media ready. Starting the virtual
//   machine." (pipeline success) was dispatched one second before auto-lock's
//   "Windows keyboard on" — the second announcement silenced the first
//   before it was heard. An 8-second pipeline makes this collision the NORM,
//   not a race. Policy now:
//     - .failure INTERRUPTS: stops current speech AND flushes any queued
//       utterances (stale success messages after a failure would mislead).
//       Failures keep their absolute right-of-way.
//     - .success and .info ENQUEUE: AVSpeechSynthesizer's native utterance
//       queue speaks them in order, nothing is lost. Sounds still play
//       immediately for every tone — the audible verdict stays real-time
//       even when its speech is waiting in line.
//
// REVISED 2026-10-18 (Allison): AVM speech should never interrupt other
//   speech if it can be helped. Failures now ENQUEUE too, and nothing is
//   flushed. The failure sound still plays the instant it happens, so the
//   verdict stays real-time. Lines are spoken in the order they happened,
//   so an older success line before a failure is history, not a claim.
//   USB sends speak at most one failure line per device, so failures no
//   longer pile up in the queue.
//
// Considered and REJECTED: UNUserNotificationCenter banners (requires a
// one-time permission grant, adds a notarization/entitlement variable) and
// NSAccessibility announcements (VoiceOver only speaks them from the FOCUSED
// app, so they cannot interrupt when AVM is in the background — the exact
// case that motivated this file).
//
// KNOWN TRADEOFFS (accepted): the system voice does not coordinate with
// VoiceOver — for rare, must-not-miss events, talking over VO is the point.
// Speech is ephemeral — the console/debug log remains the durable record.
//
// VOICEOVER FIRST (2026-10-28, the user's request: "as much as possible
// voiced by VoiceOver rather than the system voice"). With VoiceOver on:
//   - AVM in front: an accessibility announcement, which VoiceOver reads in
//     the user's own voice and rate, after what it's saying (medium
//     priority, keeping Allison's never-interrupt rule).
//   - AVM not in front, where VoiceOver doesn't read another app's
//     announcements: VoiceOver's own "output" command through AppleScript,
//     which it reads whatever app is in front. That needs VoiceOver
//     Utility's "Allow VoiceOver to be controlled with AppleScript"; until
//     it's on, those lines use the system voice, and AVM says once how to
//     turn it on.
// The system voice stays for VoiceOver off (a macOS machine has it, say)
// and for any line VoiceOver couldn't be given. The sounds are unchanged.

import AppKit
import AVFoundation

@MainActor
final class Announcer {

    static let shared = Announcer()

    enum Tone {
        case success
        case failure
        /// Neutral state transition (e.g. focus lock on/off) — neither a
        /// verdict sound (Glass/Basso) nor silent: mode changes must be
        /// audible, but must not sound like an outcome.
        case info
        /// The keyboard going to a machine, and back to the Mac
        /// (2026-10-26): a rising and a falling pair of notes of AVM's own,
        /// so where the keyboard is can be told apart from every other
        /// sound even while a screen reader talks over the words.
        case enterGuest
        case leaveGuest

        /// Distinct system sounds so the verdict is audible before the speech.
        var soundName: String? {
            switch self {
            case .success: return "Glass"
            case .failure: return "Basso"
            case .info:    return "Tink"
            case .enterGuest, .leaveGuest: return nil
            }
        }
    }

    /// The two-note sounds, made once: 90 ms per note, a fifth apart.
    private static let enterSound = twoNotes(from: 660, to: 990)
    private static let leaveSound = twoNotes(from: 990, to: 660)

    private static func twoNotes(from first: Double, to second: Double) -> NSSound? {
        let rate = 44_100.0
        let noteLength = Int(rate * 0.09)
        var samples = [Int16]()
        for frequency in [first, second] {
            for i in 0..<noteLength {
                let t = Double(i) / rate
                // A short fade in and out, so neither note clicks.
                let fade = min(1, Double(i) / 400, Double(noteLength - i) / 400)
                samples.append(Int16(sin(2 * .pi * frequency * t) * fade * 0.35 * Double(Int16.max)))
            }
        }
        var wav = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { wav.append(contentsOf: $0) } }
        let dataSize = UInt32(samples.count * 2)
        wav.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + dataSize).littleEndian)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian)
        put(UInt16(1).littleEndian); put(UInt16(1).littleEndian)          // PCM, mono
        put(UInt32(rate).littleEndian); put(UInt32(rate * 2).littleEndian)
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        wav.append(contentsOf: Array("data".utf8)); put(dataSize.littleEndian)
        samples.forEach { put($0.littleEndian) }
        return NSSound(data: wav)
    }

    /// Retained for the lifetime of the app — AVSpeechSynthesizer stops
    /// speaking if it is deallocated mid-utterance.
    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    /// Set only by the accessibility audit, before any screen opens.
    nonisolated(unsafe) static var isMuted = false

    /// True while the system voice is speaking or has lines waiting, or
    /// while VoiceOver is likely still reading AVM's last line (its own
    /// queue can't be asked, so it's estimated from the line's length).
    /// USBPlugPrompt waits on this so a plug-in alert doesn't appear
    /// while "Mac keyboard on" is still being spoken.
    var isSpeaking: Bool { synthesizer.isSpeaking || Date() < voiceOverBusyUntil }

    /// Lets what's being said finish, up to `seconds`, before AVM exits
    /// (2026-10-26, code audit): the last outcomes of a quit ("…is saved",
    /// a USB device given back) were cut off as the process ended.
    func waitUntilQuiet(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while synthesizer.isSpeaking && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    // MARK: VoiceOver first (2026-10-28)

    private var voiceOverBusyUntil = Date.distantPast
    /// VoiceOver's AppleScript refused (not allowed in VoiceOver Utility, or
    /// AVM not allowed to control it): background lines use the system
    /// voice for the rest of this run.
    private var voiceOverScriptRefused = false
    private var toldHowToAllowScripting = false
    private let scriptQueue = DispatchQueue(label: "avm.announcer.voiceover")

    /// Hands the line to VoiceOver. False when VoiceOver isn't on, or the
    /// line has to go to the system voice.
    private func speakWithVoiceOver(_ message: String) -> Bool {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return false }
        let start = max(Date(), voiceOverBusyUntil)
        voiceOverBusyUntil = start.addingTimeInterval(0.5 + Double(message.count) / 14)
        if NSApp.isActive {
            let element: Any = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp as Any
            NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
            return true
        }
        guard !voiceOverScriptRefused else { return false }
        // The line as an argument, never inside the script.
        scriptQueue.async {
            let script = Process()
            script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            script.arguments = ["-e", "on run argv", "-e", "tell application \"VoiceOver\" to output (item 1 of argv)",
                                "-e", "end run", message]
            script.standardOutput = FileHandle.nullDevice
            script.standardError = FileHandle.nullDevice
            let sent = (try? script.run()) != nil && { script.waitUntilExit(); return script.terminationStatus == 0 }()
            guard !sent else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.voiceOverScriptRefused = true
                    AVMLog.write("AVM: Announcer — VoiceOver's AppleScript refused; lines said while AVM isn't in front use the system voice.")
                    self.synthesizer.speak(AVSpeechUtterance(string: message))
                    if !self.toldHowToAllowScripting {
                        self.toldHowToAllowScripting = true
                        self.synthesizer.speak(AVSpeechUtterance(string: "To hear AVM in VoiceOver while you're in other apps, open VoiceOver Utility, and in General, turn on Allow VoiceOver to be controlled with AppleScript. Then allow AVM to control VoiceOver if your Mac asks."))
                    }
                }
            }
        }
        return true
    }

    /// Play the tone's sound immediately, then speak the message with the
    /// system voice. Every tone enqueues behind whatever is speaking, so
    /// nothing is cut off or silently eaten. See INTERRUPTION POLICY in
    /// the header (revised 2026-10-18).
    func announce(_ message: String, tone: Tone) {
        // The accessibility audit (AccessibilityAudit.swift, 2026-10-26)
        // opens AVM's screens with no one at them; their announcements are
        // kept quiet so it never talks over the user's own VoiceOver.
        guard !Self.isMuted else { return }
        // In the log as well (2026-10-26, code audit): the log's header
        // promises spoken announcements, and a failure said without its own
        // log line was missing from every diagnostic report.
        AVMLog.write("AVM: said (\(tone)) — \(message)")
        switch tone {
        case .enterGuest: Self.enterSound?.play()
        case .leaveGuest: Self.leaveSound?.play()
        default: tone.soundName.flatMap { NSSound(named: $0) }?.play()
        }

        if speakWithVoiceOver(message) { return }
        let utterance = AVSpeechUtterance(string: message)
        synthesizer.speak(utterance)
    }
}
