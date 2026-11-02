// SendToMachine.swift
// AVM — Accessible Virtual Machine
//
// Send to Virtual Machine from Finder (2026-10-31, the user's request): a
// file chosen in Finder goes to a running Windows or Linux machine's
// Downloads folder from the right-click menu (Quick Actions or Services,
// "Send to Virtual Machine"), quicker than a shared folder for one file.
// It's a macOS service (NSServices in Info.plist); the sending is
// sendFile's, through the guest agent, which says where each file landed.
// With more than one machine running, AVM asks which.

import AppKit

@MainActor
final class SendToMachineService: NSObject {
    static let shared = SendToMachineService()

    /// At launch: AVM answers the service, and macOS picks it up at once.
    static func install() {
        NSApp.servicesProvider = shared
        NSUpdateDynamicServices()
    }

    /// The service's message (NSMessage "sendToVirtualMachine").
    @objc func sendToVirtualMachine(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        AVMLog.write("AVM: Send to Virtual Machine — \(urls.count) item(s) from Finder")
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else {
            Announcer.shared.announce(urls.isEmpty ? "Nothing was chosen to send." : "Folders can't be sent, only files. Next: choose the files inside it, or zip the folder first.", tone: .info)
            return
        }
        let running = MachineSessions.shared.managers.filter { $0.state == .running }
        guard !running.isEmpty else {
            Announcer.shared.announce("No Windows or Linux machine is running, so nothing was sent. Next: start one, then send the file again.", tone: .info)
            return
        }
        let skipped = urls.count - files.count
        if skipped > 0 {
            Announcer.shared.announce("\(skipped == 1 ? "A folder was" : "\(skipped) folders were") left out: only files can be sent.", tone: .info)
        }
        guard let machine = running.count == 1 ? running[0] : choose(from: running, count: files.count) else { return }
        // Chosen in Finder, by a person; anything else can call a service too.
        let fromFinder = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        let allowed = fromFinder ? files : files.filter { Self.mayRead($0, askedBy: "Another app", machine: machine.machineName) }
        Task {
            for file in allowed { await machine.sendFile(file) }
        }
    }

    /// AVM reads the file with its own permissions, not the asker's, so
    /// another program could use it to reach a folder macOS keeps from that
    /// program (2026-11-01 audit). For those folders, the person says.
    static func mayRead(_ file: URL, askedBy: String, machine: String) -> Bool {
        let path = file.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let kept = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures"].map { "\(home)/\($0)/" }
        guard path.hasPrefix("/Volumes/") || kept.contains(where: path.hasPrefix) else { return true }
        let alert = NSAlert()
        alert.messageText = "\(askedBy) wants to send \(file.lastPathComponent) to \(machine)."
        alert.informativeText = "From \((path as NSString).deletingLastPathComponent). If you didn't ask for this, choose Don't Send."
        alert.addButton(withTitle: "Don't Send")
        alert.addButton(withTitle: "Send")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Which machine, when more than one runs: up to three by name.
    private func choose(from machines: [VMManager], count: Int) -> VMManager? {
        let shown = Array(machines.prefix(3))
        let alert = NSAlert()
        alert.messageText = "Send \(count == 1 ? "the file" : "\(count) files") to which machine?"
        alert.informativeText = "\(count == 1 ? "It goes" : "They go") to Downloads in the machine you choose."
        for machine in shown { alert.addButton(withTitle: machine.machineName) }
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return answer >= 0 && answer < shown.count ? shown[answer] : nil
    }
}
