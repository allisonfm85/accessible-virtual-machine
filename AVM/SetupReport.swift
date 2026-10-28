// SetupReport.swift
// AVM — Accessible Virtual Machine
//
// What Windows Setup installed, said out loud (2026-10-26). The answer
// file writes AVMSTATUS.TXT on the UNATTEND volume: one line per thing
// setup checked for (jaws-installed, nvda-installed, ...), and
// specialize-done / first-sign-in-done for how far it got. The first time
// a machine starts after Windows is installed, AVM reads it and says what
// is there and, by name, what isn't, with what to do. A failed installer
// is then never silent. VMManager reads the file and retires it, so the
// report is said once.

import Foundation

nonisolated enum SetupReport {

    struct Item: Sendable {
        let line: String
        let name: String
        let fix: String
    }

    static let alwaysExpected: [Item] = [
        Item(line: "vdagent-installed", name: "the mouse and clipboard agent",
             fix: "install spice-vdagent from spice-space.org in Windows"),
        Item(line: "webdavd-installed", name: "the shared-folder service",
             fix: "install spice-webdavd from spice-space.org in Windows"),
        Item(line: "qemu-ga-installed", name: "the clock agent",
             fix: "install the QEMU guest agent from the virtio-win project in Windows"),
    ]
    static let jaws = Item(line: "jaws-installed", name: "JAWS",
                           fix: "install JAWS for ARM from freedomscientific.com in Windows")
    static let nvda = Item(line: "nvda-installed", name: "NVDA",
                           fix: "install NVDA from nvaccess.org in Windows")

    /// What to say, and whether everything was there. nil: no report (a
    /// Windows installed before AVM wrote one), so nothing is said.
    static func summary(reportText: String, expectsJAWS: Bool, expectsNVDA: Bool) -> (message: String, complete: Bool, failed: Bool, signedIn: Bool)? {
        let lines = Set(reportText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        guard lines.contains("specialize-done") else { return nil }

        var expected: [Item] = []
        if expectsNVDA { expected.append(nvda) }
        if expectsJAWS { expected.append(jaws) }
        expected += alwaysExpected

        // NVDA installs at the first sign-in; before that it can't be there.
        let signedIn = lines.contains("first-sign-in-done")
        if !signedIn { expected.removeAll { $0.line == nvda.line } }

        let missing = expected.filter { !lines.contains($0.line) }
        let present = expected.filter { lines.contains($0.line) }
        var message: String
        if missing.isEmpty, !signedIn {
            // Not "everything" before the first sign-in (2026-10-28, code
            // review): said with the success sound at every Start until then.
            message = "Windows setup has installed \(list(present.map(\.name))) so far."
        } else if missing.isEmpty {
            message = "Windows setup installed everything: \(list(present.map(\.name)))."
        } else {
            message = "Windows setup finished, but \(list(missing.map(\.name))) didn't install."
            message += " Next: " + missing.map(\.fix).joined(separator: "; and ") + "."
        }
        if expectsNVDA && !signedIn {
            message += " NVDA installs when you first sign in to Windows."
        }
        return (message, missing.isEmpty && signedIn, !missing.isEmpty, signedIn)
    }

    /// "A, B and C".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "nothing"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
