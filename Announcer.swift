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

        /// Distinct system sounds so the verdict is audible before the speech.
        var soundName: String {
            switch self {
            case .success: return "Glass"
            case .failure: return "Basso"
            case .info:    return "Tink"
            }
        }
    }

    /// Retained for the lifetime of the app — AVSpeechSynthesizer stops
    /// speaking if it is deallocated mid-utterance.
    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    /// True while the system voice is speaking or has lines waiting.
    /// USBPlugPrompt waits on this so a plug-in alert doesn't appear
    /// while "Mac keyboard on" is still being spoken.
    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Play the tone's sound immediately, then speak the message with the
    /// system voice. Every tone enqueues behind whatever is speaking, so
    /// nothing is cut off or silently eaten. See INTERRUPTION POLICY in
    /// the header (revised 2026-10-18).
    func announce(_ message: String, tone: Tone) {
        NSSound(named: tone.soundName)?.play()

        let utterance = AVSpeechUtterance(string: message)
        synthesizer.speak(utterance)
    }
}
