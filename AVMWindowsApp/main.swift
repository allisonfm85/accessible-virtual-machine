// main.swift
// AVMWindowsApp — one Windows app in the Mac's Command-Tab list
//
// (2026-10-29, the user's request.) AVM copies this small program into an
// app bundle of its own for each app open in a running Windows machine
// (AVM/WindowsApps.swift), named for it, "Microsoft Word (Amena-PC)", so
// Command-Tab lists it; AVM quits it when the app closes or the machine
// stops. It has one window, which VoiceOver reads on the way in, and one
// command: Command-Shift-E, as AVM's own Enter, which asks AVM, through
// its control socket, to bring the app forward in Windows and lock the
// keyboard into it. Control-Command-Escape comes back, as always.
//
// Pinned (2026-10-30): Keep in Dock and Applications makes a lasting copy
// in /Applications/AVM Windows Apps (the home folder's Applications when
// that can't be written), in the Dock too; AVM makes it again when AVM
// itself changes. Opened by the
// person, from there or the Dock, rather than by AVM (which passes
// --avm-opened), it asks AVM to open its app: AVM opens if it isn't, the
// machine starts if it isn't running, and once Windows is signed in the
// app opens and the keyboard goes into it. A click on its Dock icon while
// it runs does the same, and so does Command-Shift-E.
//
// A machine's own app (AVMKind = machine, 2026-10-30): one for each
// running machine, named for it, so Command-Tab switches between machines.
// Switched to, or clicked in the Dock, it hands the front to AVM and asks
// it to enter the machine ("enter-machine"): its window comes forward with
// the keyboard in it. Its window shows only if AVM couldn't.
//
// Everything it needs is in its Info.plist, written by AVM: AVMAppName,
// AVMAppKey (the Windows helper's key for the app), AVMMachineID,
// AVMMachineName, AVMControlSocket, AVMBundleID (AVM's own) and AVMPinned.

import AppKit

/// What every stand-in has: its window, which VoiceOver reads, and its
/// requests to AVM. Its kind decides the rest (2026-10-30 cleanup: one
/// class with "if a machine" in each delegate method):
/// WindowsAppStandIn and MachineStandIn.
class StandIn: NSObject, NSApplicationDelegate {
    let info = Bundle.main.infoDictionary ?? [:]
    var appName: String { info["AVMAppName"] as? String ?? "Windows app" }
    var machineName: String { info["AVMMachineName"] as? String ?? "Windows" }
    /// Opened by the person, not by AVM, which passes --avm-opened.
    var openedByPerson: Bool { !CommandLine.arguments.contains("--avm-opened") }
    var window: NSWindow?
    var status: NSTextField?
    private var asking = false
    private static let noAnswer = "AVM didn't answer. Open AVM, then try again."

    func applicationDidFinishLaunching(_ notification: Notification) {}
    func applicationDidBecomeActive(_ notification: Notification) {}
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    // MARK: The window, and asking AVM

    /// The one window, which VoiceOver reads: a line, then buttons.
    func makeWindow(title: String, text: NSTextField, buttons: [NSButton]) {
        let stack = NSStackView(views: [text] + buttons)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 90 + CGFloat(buttons.count) * 40),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        status = text
    }

    /// AVM takes the front next (macOS 14 lets an app activate only when
    /// the active one yields) and is asked to act; only a refusal is said
    /// here.
    func handOver(_ command: String, showingWindowIfRefused: Bool) {
        guard !asking else { return }
        asking = true
        if #available(macOS 14.0, *), let avm = info["AVMBundleID"] as? String {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: avm)
        }
        ask(command) { reply in
            self.asking = false
            if self.sayIfRefused(reply), showingWindowIfRefused { self.window?.makeKeyAndOrderFront(nil) }
        }
    }

    /// True after saying why, when AVM said no or didn't answer.
    @discardableResult
    func sayIfRefused(_ reply: [String: Any]?) -> Bool {
        guard reply?["ok"] as? Bool != true else { return false }
        say(reply?["message"] as? String ?? Self.noAnswer)
        return true
    }

    func say(_ message: String) {
        status?.stringValue = message
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// One request to AVM; AVM opened first if it isn't answering, then
    /// asked again for up to a minute.
    func ask(_ command: String, then: @escaping ([String: Any]?) -> Void) {
        let request: [String: Any] = ["command": command,
                                      "machine": info["AVMMachineID"] as? String ?? "",
                                      "app": info["AVMAppKey"] as? String ?? "",
                                      "name": appName]
        let socketPath = info["AVMControlSocket"] as? String ?? ""
        let avm = info["AVMBundleID"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            var reply = Self.send(request, to: socketPath)
            if reply == nil, !avm.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: avm) {
                let opening = NSWorkspace.OpenConfiguration()
                opening.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: opening) { _, _ in }
                for _ in 0..<60 where reply == nil {
                    Thread.sleep(forTimeInterval: 1)
                    reply = Self.send(request, to: socketPath)
                }
            }
            DispatchQueue.main.async { then(reply) }
        }
    }

    /// One JSON line to AVM's control socket, one back (ControlServer).
    static func send(_ request: [String: Any], to path: String) -> [String: Any]? {
        guard let line = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var limit = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let out = line + Data([0x0A])
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !received.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            received.append(contentsOf: chunk[0..<n])
        }
        return try? JSONSerialization.jsonObject(with: received.prefix { $0 != 0x0A }) as? [String: Any]
    }
}

/// A Windows app's stand-in: its window says how to type in the app, and
/// it can be kept in the Dock and Applications.
final class WindowsAppStandIn: StandIn {
    private var pinned: Bool { info["AVMPinned"] as? Bool == true }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let text = NSTextField(wrappingLabelWithString: "\(appName) in \(machineName). Press Command-Shift-E to type in it. Control-Command-Escape brings you back to the Mac.")
        text.setAccessibilityLabel(text.stringValue)
        // A button too, for VoiceOver's VO-Space; Command-Shift-E is the key.
        let enter = NSButton(title: "Type in \(appName)", target: self, action: #selector(enterApp(_:)))
        let keep = NSButton(title: pinned ? "Remove from Dock and Applications" : "Keep in Dock and Applications",
                            target: self, action: #selector(togglePinned(_:)))
        makeWindow(title: "\(appName) in \(machineName)", text: text, buttons: [enter, keep])
        if !NSApp.isHidden { window?.makeKeyAndOrderFront(nil) }
        // Opened by the person, not by AVM: open the app.
        if openedByPerson { openApp() }
    }

    /// Back from Command-Tab: the window is what VoiceOver reads.
    override func applicationDidBecomeActive(_ notification: Notification) {
        window?.makeKeyAndOrderFront(nil)
    }

    /// A click on its Dock icon while it runs.
    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        openApp()
        return true
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let machineItem = NSMenuItem()
        let machineMenu = NSMenu(title: machineName)
        let enter = NSMenuItem(title: "Type in \(appName)", action: #selector(enterApp(_:)), keyEquivalent: "e")
        enter.keyEquivalentModifierMask = [.command, .shift]
        enter.target = self
        machineMenu.addItem(enter)
        let keep = NSMenuItem(title: pinned ? "Remove from Dock and Applications" : "Keep in Dock and Applications",
                              action: #selector(togglePinned(_:)), keyEquivalent: "")
        keep.target = self
        machineMenu.addItem(keep)
        machineItem.submenu = machineMenu
        main.addItem(machineItem)
        NSApp.mainMenu = main
    }

    @objc func enterApp(_ sender: Any?) { openApp() }

    /// The app, opened or brought forward in Windows, with the machine
    /// started and AVM opened as needed (WindowsApps.launch).
    private func openApp() { handOver("launch-app", showingWindowIfRefused: false) }

    @objc func togglePinned(_ sender: Any?) {
        // AVM says what happened; only a refusal is said here.
        ask(pinned ? "unpin-app" : "pin-app") { self.sayIfRefused($0) }
    }
}

/// A running machine's own app (AVMKind = machine, 2026-10-30): switched
/// to, or clicked in the Dock, it goes straight into the machine. Its
/// window shows only if AVM couldn't, to say why.
final class MachineStandIn: StandIn {
    override func applicationDidFinishLaunching(_ notification: Notification) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let enter = NSMenuItem(title: "Enter \(machineName)", action: #selector(enterMachineChosen(_:)), keyEquivalent: "e")
        enter.keyEquivalentModifierMask = [.command, .shift]
        enter.target = self
        appMenu.addItem(enter)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(machineName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
        let text = NSTextField(wrappingLabelWithString: "\(machineName): switching here puts your keyboard into it. Control-Command-Escape brings you back to the Mac.")
        let enterButton = NSButton(title: "Enter \(machineName)", target: self, action: #selector(enterMachineChosen(_:)))
        makeWindow(title: machineName, text: text, buttons: [enterButton])
        if openedByPerson { enterMachine() }
    }

    override func applicationDidBecomeActive(_ notification: Notification) { enterMachine() }

    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        enterMachine()
        return false
    }

    @objc func enterMachineChosen(_ sender: Any?) { enterMachine() }

    private func enterMachine() { handOver("enter-machine", showingWindowIfRefused: true) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate: StandIn = Bundle.main.infoDictionary?["AVMKind"] as? String == "machine" ? MachineStandIn() : WindowsAppStandIn()
app.delegate = delegate
app.run()
