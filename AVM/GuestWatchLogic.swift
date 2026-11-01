// GuestWatchLogic.swift
// AVM — Accessible Virtual Machine
//
// What GuestWatch.swift decides from (2026-10-31): its settings, what a
// machine's process list says is running, and whether its screen changed
// and which lines on it are new. Apart from the loop, so the logic tests
// reach it.

import CoreGraphics
import Foundation

nonisolated enum GuestWatchSettings {
    static let speakScreenKey = "AVMSpeakScreenChanges"
    static let restartReaderKey = "AVMRestartStoppedScreenReader"
    static let pointBeforeUpdatesKey = "AVMRestorePointBeforeUpdates"
    /// AVM's updates held while the keyboard is in a machine whose screen
    /// reader is running, and said when it comes back (Announcer, 2026-10-31).
    static let holdWhileInMachineKey = "AVMHoldUpdatesInMachine"

    /// On unless turned off, except the restore point before updates: off
    /// until turned on (2026-10-31). Twice in tests, Windows didn't come
    /// back from the restart that followed a point taken while it ran, and
    /// came back every time without one; on until that's understood would
    /// strand someone mid-update.
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? (key != pointBeforeUpdatesKey)
    }
}

// MARK: - What the machine is running

/// The screen readers and desktop seen in a machine's process list.
nonisolated struct GuestProcesses: Equatable {
    /// A user is signed in: Windows' Explorer, or a Linux desktop.
    var signedIn = false
    /// The screen readers running, by their spoken names.
    var screenReaders: Set<String> = []
    /// GNOME, where Orca has a shortcut to start it.
    var gnome = false
    /// Different after every restart (2026-10-31): Windows' smss.exe, the
    /// first process it starts, by its process number; Linux's boot_id.
    /// A restart shorter than the 16 seconds between listings got no
    /// "no answer" in between, so it went unnoticed.
    var boot: String?

    /// From `tasklist /fo csv /nh` (Windows), or the boot_id and then
    /// `ps -eo comm` (Linux).
    static func parse(_ listing: String, windows: Bool) -> GuestProcesses {
        var found = GuestProcesses()
        for raw in listing.split(whereSeparator: \.isNewline) {
            var name = raw.trimmingCharacters(in: .whitespaces)
            if windows {
                // "nvda.exe","1234","Console","1","50,000 K"
                let fields = name.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                guard name.hasPrefix("\""), let first = fields.first else { continue }
                name = first
                if name.lowercased() == "smss.exe", fields.count > 1 { found.boot = fields[1] }
            } else if found.boot == nil, name.count == 36, name.filter({ $0 == "-" }).count == 4 {
                found.boot = name
                continue
            }
            switch name.lowercased() {
            case "explorer.exe": found.signedIn = true
            case "nvda.exe": found.screenReaders.insert("NVDA")
            case "jfw.exe": found.screenReaders.insert("JAWS")
            case "narrator.exe": found.screenReaders.insert("Narrator")
            case "orca": found.screenReaders.insert("Orca")
            case "gnome-shell": found.signedIn = true; found.gnome = true
            case "plasmashell", "xfce4-session", "mate-session", "cinnamon", "lxqt-session": found.signedIn = true
            default: break
            }
        }
        return found
    }
}

// MARK: - New text on the screen

nonisolated enum ScreenChange {
    /// A screen as 64 by 36 grey levels, enough to tell a new page from a
    /// blinking cursor or a spinner.
    static func thumbnail(of image: CGImage) -> [UInt8]? {
        let w = 64, h = 36
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? pixels : nil
    }

    /// True when enough of the thumbnail moved to be a new screen: a
    /// spinner or a cursor moves a few cells, a new page many.
    static func isNewScreen(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return true }
        let moved = zip(a, b).filter { abs(Int($0) - Int($1)) > 24 }.count
        return moved > a.count / 50
    }

    /// A line as compared: lower case, letters only, so "Working on
    /// updates 23%" and "... 24%" are the same line, said once.
    static func key(_ line: String) -> String {
        String(line.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) })
    }

    /// The lines worth saying: new since the last screen said, and with
    /// some words in them (not a lone digit or a stray mark).
    static func newLines(_ lines: [String], after said: Set<String>) -> [String] {
        var seen = Set<String>()
        return lines.filter { line in
            let k = key(line)
            guard k.count >= 3, !said.contains(k), !seen.contains(k) else { return false }
            seen.insert(k)
            return true
        }
    }

    /// Windows' stop screen, said as what it is.
    static func isStopScreen(_ lines: [String]) -> Bool {
        lines.contains { $0.localizedCaseInsensitiveContains("ran into a problem") }
            && lines.contains { $0.localizedCaseInsensitiveContains("stop code") }
    }
}
