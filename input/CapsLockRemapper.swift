//
//  CapsLockRemapper.swift
//  AVM
//
//  Created by Allison Meloy on 7/26/26.
//


// CapsLockRemapper.swift
// AVM — Accessible Virtual Machine
//
// Owns the Caps Lock → F19 hidutil remap and its full lifecycle.
//
// WHY THIS EXISTS (root cause, Handoff 17):
//   macOS resolves Caps Lock inside the HID driver. It flips the lock state
//   and the LED itself and hands the application only a flagsChanged
//   notification describing the RESULTING STATE — never a press followed by a
//   release. A HELD Caps Lock cannot be expressed at all. Every guest screen
//   reader needs that hold: JAWS and NVDA use Caps Lock as their modifier in
//   laptop layout, and Narrator's DEFAULT modifier is "Caps lock or Insert".
//   No Mac keyboard has Insert and a MacBook has no numpad, so laptop layout
//   is the only option and there is no fallback modifier. Without this remap,
//   AVM's own documented path (Narrator) is broken.
//
//   The fix: hidutil remaps Caps Lock → F19 at the driver level, below the
//   layer that swallows it. VMView's scancode table maps kVK_F19 → 0x3A
//   (Caps Lock's own scancode), so the guest receives a genuine, held Caps
//   Lock. F19 was chosen because no Mac keyboard has one, macOS assigns it no
//   meaning, and it has no press-and-hold accent menu to intercept the hold.
//
// WHY hidutil AND NOT AN EVENT TAP:
//   hidutil needs no permission prompt. A CGEventTap needs Input Monitoring,
//   and a surprise permissions dialog while VoiceOver is asleep is precisely
//   the failure mode AVM exists to prevent. (AVM previously carried a
//   never-started CGEventTap that claimed to do this job; it was removed
//   2026-07-26. It could never have worked — see the root cause above.)
//
// LIFECYCLE — apply on lock, restore on unlock, plus two safety nets:
//   Mac-side Caps Lock must stay normal whenever the keyboard is not in
//   Windows. But a remap that outlives the app is a serious, silent
//   degradation of the user's whole machine: Caps Lock dead, no caps, no
//   screen-reader modifier, no explanation. So restoration is attempted from
//   three places:
//     1. unlock()                    — the ordinary path
//     2. applicationWillTerminate    — ordinary quit (Cmd-Q)
//     3. recoverAtLaunch()           — crash and force-quit, where nothing runs
//   Reboot also clears any mapping (they are not persistent), which is the
//   last-resort user-facing remedy and belongs in the tester guide.
//
// PRESERVING THE USER'S OWN REMAPS (merge, not replace):
//   `--set` replaces the ENTIRE mapping array. A user who has already remapped
//   keys themselves would have those silently clobbered. Blind Mac users remap
//   keys more often than most. So on lock we READ the existing array, keep
//   every entry whose source is not Caps Lock, add ours, and apply the union;
//   on unlock we restore exactly what was there before. Their Escape or arrow
//   remaps keep working inside Windows; only Caps Lock changes, which is the
//   entire point of the feature.
//
// FAIL SAFE, NOT FAIL FUNCTIONAL:
//   If the READ fails we do NOT apply. We cannot restore a baseline we never
//   captured, and applying blind could destroy the user's existing remaps
//   permanently. Better that Caps Lock stays broken in the guest for this
//   session than that AVM wrecks the user's Mac configuration.
//
// SILENCE IS NEVER NEUTRAL:
//   If the remap fails, Caps Lock silently stops being a modifier and every
//   guest screen reader loses its command key with no signal. That is a silent
//   failure in exactly the place this project refuses to have them. Failures
//   announce with .failure. SUCCESS IS SILENT — it rides the existing
//   "Windows keyboard on" transition.
//
// ANNOUNCEMENT ORDERING CONTRACT (important, and easy to get wrong):
//   .failure INTERRUPTS and FLUSHES the Announcer queue. So the apply attempt
//   must happen BEFORE FocusLockManager speaks "Windows keyboard on" — if it
//   came after, a failure would cut the mode-change announcement off mid-word.
//   Applying first means the warning speaks cleanly and "Windows keyboard on"
//   enqueues behind it. Odd to read on paper; correct to hear.
//
// hidutil FORMAT FACTS (verified live 2026-07-26, not assumed):
//   - `--set` takes JSON. JSON cannot express hex literals, so we write
//     DECIMAL. Verified: decimal in, identical output back.
//   - `--get` returns an OLD-STYLE ASCII property list, NOT JSON, and NOT the
//     same shape as `--set` echoes: `--set` prints "UserKeyMapping:(...)"
//     while `--get` prints a bare "(...)". We only ever parse `--get`.
//   - `--get` prints Dst BEFORE Src (alphabetical), which is the reverse of
//     the order we write them. A parser that paired consecutive numbers by
//     POSITION would silently invert every one of the user's mappings on
//     restore. Fields are therefore always extracted BY NAME.
//   - Measured at 5–8 ms per invocation, so the two calls at lock cost roughly
//     30 ms including process spawn. Synchronous is comfortable, and
//     synchronous is required: applicationWillTerminate has no time for an
//     async completion to land.
//
// STAGE C LOGGING DISPOSITION (2026-08-03) — three tiers, decided together:
//   1. PROMOTED to AVMLog (file log): the applyForLock lines and the launch-
//      recovery lines. Apply runs only at lock time and recovery only at
//      launch — both safe contexts for the async file logger — and they are
//      the charter's "Caps Lock remap apply/restore" category: the lines that
//      diagnose "my screen reader commands don't work in Windows."
//   2. CONTEXT-SPLIT in restore(): one shared implementation serves unlock,
//      termination, and launch recovery. AVMLog.write dispatches via
//      queue.async, and a write enqueued inside applicationWillTerminate can
//      be lost when the process exits before the block runs — silently, which
//      is worse than not promoting. So restore() derives its log sink from
//      its context parameter: file log for "unlock" and "launch recovery"
//      (frequent / diagnostic-critical), NSLog for "termination" (the unified
//      log keeps it, beside the AppDelegate's own termination line, which
//      stays on NSLog permanently for the same reason — see AVMApp.swift).
//   3. NSLog PERMANENTLY: the hidutil helper lines (readCurrentMapping,
//      writeMapping, runHidutil, parseMapping). These are called FROM the
//      termination path, so promoting them re-opens the trap tier 2 closes;
//      and every helper failure already propagates to a tier-1/2 verdict line
//      ("apply FAILED", "restore FAILED") that does reach the file log. File
//      log carries the verdict; unified log carries the forensic detail.

import Foundation
import AppKit

@MainActor
final class CapsLockRemapper {

    // MARK: - Shared instance

    static let shared = CapsLockRemapper()

    private init() {}

    // MARK: - HID usage constants
    //
    // Decimal, because that is what we must write in JSON. The hex forms are
    // given for cross-reference with Apple's HID usage tables and with the
    // hand-applied Terminal commands in Handoff 17.
    //   Caps Lock  0x700000039  = 30064771129
    //   F19        0x70000006E  = 30064771182

    private static let capsLockUsage: UInt64 = 30_064_771_129
    private static let f19Usage: UInt64 = 30_064_771_182

    // MARK: - UserDefaults keys

    /// Decision 4: on by default, with a setting to disable. Narrator's
    /// default modifier settles this — it is not really a preference, it is
    /// required for AVM's documented path to work at all. The disable switch
    /// exists as an escape hatch, not as an invitation.
    static let enabledKey = "AVMCapsLockRemapEnabled"

    /// True between a successful apply and a successful restore. This is the
    /// ONLY thing that authorizes launch recovery to touch the system.
    private static let activeKey = "AVMCapsLockRemapActive"

    /// JSON of the mapping array as it existed BEFORE we applied ours.
    private static let savedMappingKey = "AVMCapsLockSavedMapping"

    // MARK: - Public state

    /// Absent means ON. A user who has never touched the setting gets the
    /// working configuration.
    var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Model

    private struct KeyMapping: Codable, Equatable {
        let src: UInt64
        let dst: UInt64
    }

    // MARK: - Lock / unlock entry points

    /// Called from FocusLockManager.lock() BEFORE the "Windows keyboard on"
    /// announcement. See the ordering contract in the header.
    ///
    /// Log lines here are file-log (Stage C tier 1): apply runs only at lock
    /// time, never at quit, so the async file logger is a safe sink.
    func applyForLock() {
        guard isEnabled else {
            AVMLog.write("AVM: CapsLockRemapper — disabled by setting; not applying.")
            return
        }

        // Read first. If we cannot read, we do not write — see FAIL SAFE.
        guard let existing = readCurrentMapping() else {
            AVMLog.write("AVM: CapsLockRemapper — FAILED to read current mapping; NOT applying (fail safe).")
            Announcer.shared.announce(
                "Caps Lock setup failed. Screen reader commands may not work.",
                tone: .failure)
            return
        }

        // Merge: keep everything that is not a Caps Lock source, add ours.
        let preserved = existing.filter { $0.src != Self.capsLockUsage }
        let merged = preserved + [KeyMapping(src: Self.capsLockUsage, dst: Self.f19Usage)]

        // Persist the ORIGINAL and flush BEFORE applying. Order matters: a
        // crash between the write and the apply means launch recovery restores
        // what was already in place, which is a harmless no-op. A crash after
        // the apply is exactly what the saved copy is for. There is no window
        // in which we have changed the system without having recorded how to
        // put it back.
        if let encoded = try? JSONEncoder().encode(existing),
           let json = String(data: encoded, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: Self.savedMappingKey)
        } else {
            AVMLog.write("AVM: CapsLockRemapper — could not encode saved mapping; NOT applying (fail safe).")
            Announcer.shared.announce(
                "Caps Lock setup failed. Screen reader commands may not work.",
                tone: .failure)
            return
        }
        UserDefaults.standard.set(true, forKey: Self.activeKey)
        UserDefaults.standard.synchronize()

        if writeMapping(merged) {
            AVMLog.write("AVM: CapsLockRemapper — APPLIED (preserved \(preserved.count) existing entr\(preserved.count == 1 ? "y" : "ies")). Success is silent by design.")
        } else {
            // The write failed, so the system is unchanged. Clear the flag so
            // launch recovery does not later "restore" over a system we never
            // touched.
            UserDefaults.standard.set(false, forKey: Self.activeKey)
            UserDefaults.standard.removeObject(forKey: Self.savedMappingKey)
            UserDefaults.standard.synchronize()
            AVMLog.write("AVM: CapsLockRemapper — apply FAILED; flag cleared.")
            Announcer.shared.announce(
                "Caps Lock setup failed. Screen reader commands may not work.",
                tone: .failure)
        }
    }

    /// Called from FocusLockManager.unlock(). Announces on failure, because a
    /// Caps Lock left pointing at F19 after the user has returned to the Mac
    /// is dead on their machine with no explanation.
    ///
    /// WORDING NOT YET APPROVED — flagged for review. The apply-failure text
    /// was approved in Handoff 17; this one is new. It is deliberately
    /// actionable and deliberately true: mappings do not survive a reboot
    /// (verified), so restarting is a genuine remedy rather than a shrug.
    func restoreForUnlock() {
        restore(announceFailure: true, context: "unlock")
    }

    /// Called from applicationWillTerminate. Silent: the app is going away and
    /// speech will not reliably be heard, so an announcement here would be a
    /// promise we cannot keep. The launch-recovery net covers what this misses.
    func restoreForTermination() {
        restore(announceFailure: false, context: "termination")
    }

    // MARK: - Launch recovery

    /// Called once at app launch, from the app delegate.
    ///
    /// Catches the cases where no code of ours got to run: crash, force quit,
    /// power loss. If the active flag is not set we touch NOTHING — that is
    /// what protects a user who maintains their own persistent Caps Lock remap
    /// (installed via a login item, since hidutil mappings die at reboot) from
    /// having AVM wipe it on launch.
    ///
    /// Log lines here are file-log (Stage C tier 1): launch is a safe context
    /// for the async file logger, and a stranded-remap recovery is exactly the
    /// event a diagnostic log must carry — it explains a "my whole Mac's Caps
    /// Lock was broken" report.
    func recoverAtLaunch() {
        guard UserDefaults.standard.bool(forKey: Self.activeKey) else {
            AVMLog.write("AVM: CapsLockRemapper — launch recovery: no stranded remap flagged; touching nothing.")
            return
        }

        AVMLog.write("AVM: CapsLockRemapper — launch recovery: stranded remap flagged (AVM did not exit cleanly).")

        // Belt and braces: confirm OUR entry is actually present before
        // restoring. If the flag is set but Caps Lock is no longer mapped to
        // F19, something else has changed the mapping since we died — a
        // reboot, or the user's own tooling. Stomping on whatever is now in
        // place would be worse than doing nothing.
        if let current = readCurrentMapping() {
            let oursPresent = current.contains {
                $0.src == Self.capsLockUsage && $0.dst == Self.f19Usage
            }
            if !oursPresent {
                AVMLog.write("AVM: CapsLockRemapper — launch recovery: our entry is NOT present; clearing flag, leaving system alone.")
                clearSavedState()
                return
            }
        }

        restore(announceFailure: false, context: "launch recovery")
    }

    // MARK: - Restore (shared implementation)

    /// STAGE C tier 2 (2026-08-03): the sink is derived from the context.
    /// "termination" runs inside applicationWillTerminate, where an
    /// AVMLog.write enqueued on the serial queue can be lost at process exit
    /// — so that context logs via NSLog (the unified log keeps it). The
    /// other contexts ("unlock", "launch recovery") go to the file log:
    /// unlock is the most frequent focus transition in the app, and both are
    /// lines a field diagnosis acts on.
    private func restore(announceFailure: Bool, context: String) {
        let log: (String) -> Void = (context == "termination")
            ? { NSLog("%@", $0) }
            : { AVMLog.write($0) }

        guard UserDefaults.standard.bool(forKey: Self.activeKey) else {
            // Nothing of ours is applied. Never write in this case: a blind
            // write would clobber mappings we do not own.
            log("AVM: CapsLockRemapper — restore (\(context)): not active; no-op.")
            return
        }

        // Absence of a saved blob means "there was nothing before" — an empty
        // array is the correct restore target, not a reason to bail.
        var original: [KeyMapping] = []
        if let json = UserDefaults.standard.string(forKey: Self.savedMappingKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([KeyMapping].self, from: data) {
            original = decoded
        } else {
            log("AVM: CapsLockRemapper — restore (\(context)): no decodable saved mapping; restoring to empty.")
        }

        if writeMapping(original) {
            clearSavedState()
            log("AVM: CapsLockRemapper — RESTORED (\(context)); \(original.count) original entr\(original.count == 1 ? "y" : "ies") put back.")
        } else {
            // Deliberately DO NOT clear the flag: the remap is still live, and
            // the flag is what lets the next launch try again.
            log("AVM: CapsLockRemapper — restore FAILED (\(context)); flag left set for next launch.")
            if announceFailure {
                Announcer.shared.announce(
                    "Caps Lock could not be returned to normal. Restart your Mac to fix it.",
                    tone: .failure)
            }
        }
    }

    private func clearSavedState() {
        UserDefaults.standard.set(false, forKey: Self.activeKey)
        UserDefaults.standard.removeObject(forKey: Self.savedMappingKey)
        UserDefaults.standard.synchronize()
    }

    // MARK: - hidutil read
    //
    // STAGE C tier 3: NSLog permanently in this helper and the ones below —
    // they run on the termination path too, and their failures always
    // propagate to a tier-1/2 verdict line in the file log.

    /// Returns nil on FAILURE. Returns an empty array when there genuinely are
    /// no mappings. That distinction is load-bearing: "no mappings" is a valid
    /// baseline to restore to, while "could not read" must stop us writing.
    private func readCurrentMapping() -> [KeyMapping]? {
        guard let result = Self.runHidutil(["property", "--get", "UserKeyMapping"]) else {
            return nil
        }
        guard result.status == 0 else {
            NSLog("AVM: CapsLockRemapper — hidutil --get exited \(result.status).")
            return nil
        }
        return Self.parseMapping(result.output)
    }

    // MARK: - hidutil write

    private func writeMapping(_ mappings: [KeyMapping]) -> Bool {
        let entries = mappings.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}"
        }.joined(separator: ",")
        let json = "{\"UserKeyMapping\":[\(entries)]}"

        guard let result = Self.runHidutil(["property", "--set", json]) else {
            return false
        }
        guard result.status == 0 else {
            NSLog("AVM: CapsLockRemapper — hidutil --set exited \(result.status). Output: \(result.output)")
            return false
        }
        return true
    }

    // MARK: - Parsing
    //
    // Fields are extracted BY NAME, never by position — `--get` prints Dst
    // before Src, so positional pairing would invert every mapping. Decimal is
    // what we have observed; the optional 0x branch is defensive in case a
    // future macOS prints hex, and costs nothing.
    //
    // ACCESS LEVEL: this MUST be private, because it returns [KeyMapping] and
    // KeyMapping is private. Swift refuses an internal method whose signature
    // exposes a private type — the caller could not name the return value.
    // (Compile error 2026-07-26: "Method must be declared private because its
    // result uses a private type.")

    nonisolated private static func parseMapping(_ text: String) -> [KeyMapping] {
        var results: [KeyMapping] = []

        guard let blockRegex = try? NSRegularExpression(pattern: "\\{[^{}]*\\}", options: []) else {
            return results
        }
        let full = NSRange(text.startIndex..., in: text)
        let blocks = blockRegex.matches(in: text, options: [], range: full)

        for block in blocks {
            guard let blockRange = Range(block.range, in: text) else { continue }
            let blockText = String(text[blockRange])
            guard let src = field("HIDKeyboardModifierMappingSrc", in: blockText),
                  let dst = field("HIDKeyboardModifierMappingDst", in: blockText) else {
                NSLog("AVM: CapsLockRemapper — skipping unparseable mapping block.")
                continue
            }
            results.append(KeyMapping(src: src, dst: dst))
        }
        return results
    }

    nonisolated private static func field(_ name: String, in text: String) -> UInt64? {
        let pattern = "\(name)\\s*=\\s*(0[xX][0-9a-fA-F]+|[0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }

        let raw = String(text[valueRange])
        if raw.lowercased().hasPrefix("0x") {
            return UInt64(raw.dropFirst(2), radix: 16)
        }
        return UInt64(raw)
    }

    // MARK: - Process invocation
    //
    // Synchronous by design: applicationWillTerminate has no time for an async
    // completion to land, and measured cost is 5–8 ms. The watchdog exists
    // because a main-thread block is the one thing worse than a failed remap —
    // it would present to a blind user as a total freeze with no speech at all.
    //
    // Pipes are drained BEFORE waitUntilExit. readDataToEndOfFile returns at
    // EOF, which is process exit, so this both avoids a full-pipe deadlock and
    // makes the wait a formality.

    nonisolated private static func runHidutil(
        _ args: [String],
        timeout: TimeInterval = 5.0
    ) -> (status: Int32, output: String)? {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            NSLog("AVM: CapsLockRemapper — could not launch hidutil: \(error.localizedDescription)")
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning {
                NSLog("AVM: CapsLockRemapper — hidutil exceeded \(timeout)s; terminating.")
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        if !err.isEmpty {
            NSLog("AVM: CapsLockRemapper — hidutil stderr: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return (process.terminationStatus, out)
    }
}
