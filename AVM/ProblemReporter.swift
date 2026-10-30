// ProblemReporter.swift
// AVM — Accessible Virtual Machine
//
// Help > Report a Problem… (2026-10-26): one step from "something went
// wrong" to a GitHub issue with what a fix needs. AVM puts a report on the
// clipboard (AVM, macOS and Mac versions, and the last part of the
// diagnostic log, sanitized as always: no user name, no keystrokes), then
// opens a new issue in the browser, whose text says to paste it in. The
// report never goes into the web address, so it stays out of browser
// history and isn't cut short. Nothing is sent until the user submits the
// issue on GitHub, after reading and changing it as they like.
// Save Diagnostic Log still gives the whole log as files.

import AppKit

@MainActor
enum ProblemReporter {

    // The template named in the address (2026-10-29, seventh audit): with
    // templates in the repository, a bare issues/new is GitHub's chooser
    // page, one more step before the form.
    static let newIssueURL = "https://github.com/allisonfm85/accessible-virtual-machine/issues/new?template=report-a-problem.md"
    /// Lines from the end of the log; enough for the last start, short
    /// enough to read before submitting.
    static let logLines = 120

    static func reportAProblem() {
        let alert = NSAlert()
        alert.messageText = "Report a problem on GitHub?"
        alert.informativeText = "AVM puts a report on the clipboard: your AVM, macOS and Mac versions, and the last part of the diagnostic log, which never has your user name or anything you typed. Then it opens a new GitHub issue in your browser. Describe what happened, paste the report with Command-V, and submit. Nothing is sent until you submit it, and you can read and change everything first. You need to be signed in to GitHub."
        alert.addButton(withTitle: "Copy Report and Open GitHub")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let report = makeReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        AVMLog.write("AVM: Report a Problem — report copied (\(report.count) characters); opening a new GitHub issue.")

        var components = URLComponents(string: newIssueURL)
        // Added to the template item, not in its place.
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "body", value: "What happened, and what you expected:\n\n\n\nAVM's report (paste it below with Command-V):\n\n"))
        components?.queryItems = items
        if let url = components?.url {
            NSWorkspace.shared.open(url)
        }
        Announcer.shared.announce("The report is on the clipboard, and GitHub's new issue page is opening in your browser. Describe what happened, then paste the report with Command-V.", tone: .info)
    }

    static func makeReport() -> String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (build \(info?["CFBundleVersion"] as? String ?? "?"))"
        var log = "(no diagnostic log yet)"
        if let url = AVMLog.currentLogURL(), let text = try? String(contentsOf: url, encoding: .utf8) {
            let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(logLines).joined(separator: "\n")
            log = AVMLog.sanitize(tail)
        }
        return """
        AVM \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(macModel())

        <details><summary>Diagnostic log, last \(logLines) lines</summary>

        ```
        \(log)
        ```
        </details>
        """
    }

    private static func macModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
