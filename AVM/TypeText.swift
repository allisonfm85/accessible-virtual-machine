// TypeText.swift
// AVM — Accessible Virtual Machine
//
// Type the clipboard into the machine (2026-10-30, the user's request):
// sign-in screens, some installers and some web forms refuse paste, and a
// long password or product key is hard to type by ear. Virtual Machine >
// Type Clipboard into Windows types the Mac's clipboard text as key presses,
// through the machine's own virtual keyboard (QMP send-key), as Send
// Ctrl-Alt-Delete does, so it works before the guest's agents are up.
//
// The keys are the US layout's, which is what AVM's installs set up
// (en-US Windows, "us" for Linux). A character with no key there, such as
// an accented letter, is skipped and counted, and AVM says how many. The
// text itself is never logged or spoken: it's often a password.

import Foundation

extension VMManager {

    /// The US-layout key for a character, and whether it needs Shift.
    nonisolated static func usKey(for character: Character) -> (qcode: String, shift: Bool)? {
        switch character {
        case "a"..."z": return (String(character), false)
        case "A"..."Z": return (character.lowercased(), true)
        case "0"..."9": return (String(character), false)
        case " ": return ("spc", false)
        case "\n", "\r", "\r\n": return ("ret", false)
        case "\t": return ("tab", false)
        default: break
        }
        let plain: [Character: String] = [
            "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
            ";": "semicolon", "'": "apostrophe", "`": "grave_accent", ",": "comma", ".": "dot", "/": "slash",
        ]
        if let qcode = plain[character] { return (qcode, false) }
        let shifted: [Character: String] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "minus", "+": "equal", "{": "bracket_left", "}": "bracket_right", "|": "backslash",
            ":": "semicolon", "\"": "apostrophe", "~": "grave_accent", "<": "comma", ">": "dot", "?": "slash",
        ]
        if let qcode = shifted[character] { return (qcode, true) }
        return nil
    }

    /// Types `text` into the machine. Returns how many characters were
    /// typed and how many had no key, or nil when it couldn't type at all.
    func typeText(_ text: String) async -> (typed: Int, skipped: Int)? {
        guard case .running = state else { return nil }
        var typed = 0
        var skipped = 0
        for character in text {
            guard let key = Self.usKey(for: character) else {
                skipped += 1
                continue
            }
            var keys: [[String: String]] = []
            if key.shift { keys.append(["type": "qcode", "data": "shift"]) }
            keys.append(["type": "qcode", "data": key.qcode])
            do {
                try await sendQMPCommand("send-key", arguments: ["keys": keys, "hold-time": 15])
                typed += 1
            } catch {
                AVMLog.write("AVM: Type Clipboard — stopped after \(typed) characters: \(error.localizedDescription)")
                return typed == 0 ? nil : (typed, skipped)
            }
            // A moment between keys, so a slow screen or a sign-in box
            // doesn't drop any.
            try? await Task.sleep(for: .milliseconds(15))
        }
        AVMLog.write("AVM: Type Clipboard — typed \(typed) characters, \(skipped) without a key")
        return (typed, skipped)
    }
}
