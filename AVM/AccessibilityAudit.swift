// AccessibilityAudit.swift
// AVM — Accessible Virtual Machine
//
// An automatic accessibility check of AVM's own windows (2026-10-26), for
// Tools/audit-accessibility.sh:
//
//   AVM.app/Contents/MacOS/AVM --audit-accessibility --out <folder>
//       [--only <screen name>] [--keep]
//
// It opens each of AVM's screens with sample machines, the way a person
// would meet them, and reads them the way VoiceOver does: through the
// accessibility tree AppKit and SwiftUI give assistive technology. Then
// it writes <folder>/accessibility-report.txt (one line per finding:
// level, screen, role, path, problem), <folder>/accessibility-tree.txt
// (everything it read, for working out a finding), prints a summary, and
// exits 0 when there is no finding at error level, 1 when there is.
// --only checks just the screens whose names contain the words given.
// Without the flag it does nothing at all.
//
// ISOLATION. Before anything reads or writes, AVMPaths' support folder is
// pointed at a new temporary folder, so the sample machines (a Windows, an
// Ubuntu and a macOS one, with restore points, a shared folder,
// remembered USB devices and two leftover folders for Reclaim) and every
// log line go there. The user's own machine list is never opened. The
// folder is deleted at the end, unless --keep. Announcements are muted,
// so nothing talks over the user's VoiceOver; AVM takes no Dock icon and
// never becomes the active app, and its windows are placed off every
// screen, so nothing takes focus from what the user is doing.
//
// WHAT IS CHECKED, per screen:
//   - error: a control (button, checkbox, radio button and group, text
//     field, pop-up, combo box, slider, stepper, link) with no label or
//     title, so VoiceOver says only "button";
//   - error: an image with no label that isn't hidden;
//   - error: two or more controls of one kind with the same label, such as
//     several "Delete" buttons without the machine's name;
//   - error: a heading the tester guide promises (section 5 for the
//     dashboard, section 6 for the Setup Wizard), or a screen's title
//     heading, that isn't there, or is at another level;
//   - warning: a label that says the same words twice ("Privacy,
//     Privacy"), which SwiftUI makes of a control's title plus an
//     accessibilityLabel that repeats it;
//   - warning: a text field named only by its placeholder;
//   - warning: a control keyboard focus can't be put on (see KEYBOARD).
//
// HOW IT READS THE TREE. Each screen is hosted in an NSHostingView in its
// own NSWindow, laid out, and given a few run loop turns (and its .task
// work, such as reading restore points with qemu-img) before the content
// view's accessibilityChildren are walked, in-process. Two things were
// measured on the way (2026-10-26):
//   1. SwiftUI builds its accessibility nodes only once an assistive
//      technology has said it is there. Until then every hosting view
//      reports no children at all. The audit says it is there itself, as
//      VoiceOver does when it attaches, by setting AXEnhancedUserInterface
//      on the application; the trees then appear within a second. No
//      assistive technology needs to be running, and no permission.
//   2. SwiftUI's nodes (AccessibilityNode) answer the NSAccessibility
//      methods without declaring the protocol, so they are asked through
//      an all-optional @objc protocol (AXInformal, below), with the older
//      attribute-name API as a fallback.
// The AX API (AXUIElementCreateApplication) is not used. In this run
// mode, before AVM's own launch, every AX request to AVM answers
// kAXErrorCannotComplete, and after NSApp.finishLaunching the AX server
// gives only the application element, as its own window and child, from
// this process or another; the in-process objects are the ones the AX
// server hands VoiceOver in a normal run. If a screen ever comes back with
// no controls, it is reported as not checked, at error level.
//
// KEYBOARD. Tab can't be pressed for real: SwiftUI moves keyboard focus
// only in the key window of the active app, and the audit never makes AVM
// the active app (it would take focus from the user). So each enabled
// control is asked whether focus can be put on it: an NSView that can
// become the key view, or an element whose AXFocused can be set, which is
// how Tab (with Keyboard navigation on) and VoiceOver put focus on
// SwiftUI's controls. With Keyboard navigation off (System Settings,
// Keyboard), macOS's own rule is that Tab reaches only text fields and
// lists, so only those are reported then. The setting is read, never
// changed.
//
// WHAT IT CANNOT SEE: the order Tab really goes in; NSAlert and
// NSOpenPanel dialogs (they are modal and would wait for a person); the
// VM window itself (VMView needs a running machine) and the screens of a
// running machine (Enter, Pause, Shut Down); the menu bar; what is spoken
// (Announcer); heading levels, which SwiftUI on macOS doesn't expose to
// assistive technology at all (see headingLevelsReported); and whether a
// label is worded well. A label that is present but wrong, or a reading
// order that makes no sense, still needs a person with VoiceOver.

import AppKit
import SwiftUI

@MainActor
enum AccessibilityAudit {

    static let flag = "--audit-accessibility"

    /// Called first thing at launch; returns only when not asked.
    static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(flag) else { return }
        func value(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard let out = value("--out") else {
            print("Usage: AVM \(flag) --out <folder> [--only <screen name>] [--keep]")
            exit(64)
        }
        let keep = arguments.contains("--keep")
        let only = value("--only")
        // --pictures FOLDER (2026-10-28): each screen as an image, in light
        // and dark appearance, for a sighted look at what VoiceOver reads.
        Auditor.pictures = value("--pictures").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let pictures = Auditor.pictures { try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true) }
        // --dark: the whole run in dark appearance (a window's own appearance
        // switch didn't redraw for the picture).
        Auditor.dark = arguments.contains("--dark")
        if Auditor.dark { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Isolation first, before anything reads or writes (see header).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AVM-accessibility-audit-\(UUID().uuidString)", isDirectory: true)
        let support = scratch.appendingPathComponent("Support", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        AVMPaths.supportDirectoryOverride = support
        Announcer.isMuted = true
        NSApplication.shared.setActivationPolicy(.prohibited)
        // What VoiceOver tells an app when it attaches (see HOW IT READS
        // THE TREE, 1). Set through the informal
        // accessibilitySetValue:forAttribute:, as the AX API would; KVC on
        // NSApp has no such key and throws.
        _ = (NSApplication.shared as AnyObject).perform(
            Selector(("accessibilitySetValue:forAttribute:")),
            with: NSNumber(value: true), with: "AXEnhancedUserInterface")

        func finish(_ code: Int32) -> Never {
            if keep {
                print("Sample machines kept in \(scratch.path)")
            } else {
                try? FileManager.default.removeItem(at: scratch)
            }
            exit(code)
        }
        Task { @MainActor in
            let auditor = Auditor(scratch: scratch, out: folder, only: only)
            finish(await auditor.run())
        }
        // The app's run loop hasn't started yet; this one serves the
        // screens and the audit until it is done (finish exits).
        while true {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

// MARK: - What is read

/// One element of a screen's accessibility tree, as VoiceOver would meet it.
private struct AuditNode {
    var role: String
    var subrole: String
    var label: String
    var title: String
    var value: String
    var placeholder: String
    /// What VoiceOver says after a pause: AXHelp (SwiftUI's accessibilityHint).
    var hint: String = ""
    /// What VoiceOver says for its kind, "text field" or "pop-up button":
    /// AXRoleDescription.
    var roleDescription: String = ""
    var enabled: Bool
    /// The heading level reported as AXValue, as WebKit gives it; 0 when
    /// none is (always, from SwiftUI on macOS: see headingLevelsReported).
    var headingLevel: Int
    var path: String
    var depth: Int
    /// Whether keyboard focus can be put on it: an NSView that can become
    /// the key view, or an element whose AXFocused can be set. nil when
    /// that couldn't be asked.
    var focusable: Bool?

    /// What VoiceOver says for its name: the label, else the title.
    var name: String {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !l.isEmpty { return l }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isHeading: Bool { role == "AXHeading" }

    /// Visible text for a static text or heading: its name or value.
    var text: String { name.isEmpty ? value : name }

    static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXRadioGroup", "AXTextField", "AXTextArea",
        "AXPopUpButton", "AXComboBox", "AXSlider", "AXIncrementor", "AXLink", "AXMenuButton",
        "AXDisclosureTriangle", "AXSearchField", "AXColorWell", "AXDateField",
    ]
    var isControl: Bool { Self.controlRoles.contains(role) }
    var isTextEntry: Bool { role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" || role == "AXSearchField" }

    var describe: String {
        var parts = [role + (subrole.isEmpty ? "" : "/\(subrole)")]
        if !label.isEmpty { parts.append("label=\"\(label)\"") }
        if !title.isEmpty { parts.append("title=\"\(title)\"") }
        if !value.isEmpty { parts.append("value=\"\(value.prefix(80))\"") }
        if !placeholder.isEmpty { parts.append("placeholder=\"\(placeholder)\"") }
        if !hint.isEmpty { parts.append("hint=\"\(hint.prefix(100))\"") }
        if isControl && !roleDescription.isEmpty { parts.append("says=\"\(roleDescription)\"") }
        if headingLevel > 0 { parts.append("level=\(headingLevel)") }
        if !enabled { parts.append("dimmed") }
        if isControl && focusable == false { parts.append("no-keyboard-focus") }
        return parts.joined(separator: " ")
    }
}

private struct Finding {
    enum Level: String { case error, warning, note }
    let level: Level
    let screen: String
    let role: String
    let path: String
    let problem: String

    var line: String { "\(level.rawValue.uppercased())\t\(screen)\t\(role)\t\(path)\t\(problem)" }
}

/// A heading a screen must have: its text ("" for any), and the level
/// when one is promised (0: any level).
private struct ExpectedHeading {
    let text: String
    let level: Int
    let source: String
}

private struct Screen {
    let name: String
    let size: NSSize
    let headings: [ExpectedHeading]
    let make: () -> AnyView
}

// MARK: - The audit

@MainActor
private final class Auditor {
    let scratch: URL
    let out: URL
    let only: String?
    var findings: [Finding] = []
    var treeDump: [String] = []
    var summary: [String] = []
    /// Whether any heading on any screen reported a level. SwiftUI on
    /// macOS (measured 2026-10-26, macOS 27) gives .accessibilityHeading's
    /// level to no attribute at all: a heading's AXValue is empty and its
    /// attribute names add only AXAttributedDescription. While that is so,
    /// a promised level can't be checked, and the report says so once
    /// instead of failing every heading.
    var headingLevelsReported = false
    var levelChecksSkipped = 0

    init(scratch: URL, out: URL, only: String?) {
        self.scratch = scratch
        self.out = out
        self.only = only
    }

    /// Keyboard navigation (Full Keyboard Access for Tab): bit 2 is on.
    lazy var keyboardNavigationOn: Bool = {
        let mode = CFPreferencesCopyAppValue("AppleKeyboardUIMode" as CFString, kCFPreferencesAnyApplication) as? Int ?? 0
        return mode & 2 != 0
    }()

    func run() async -> Int32 {
        print("AVM accessibility audit")
        print("Sample machines in \(scratch.path) (the real machine list is not opened).")
        print("Keyboard navigation is \(keyboardNavigationOn ? "on: every control should take keyboard focus" : "off: only text fields are expected to take keyboard focus with Tab").")
        fflush(stdout)

        let samples: Samples
        do {
            samples = try await Samples.make(in: scratch)
        } catch {
            print("FAILED: the sample machines could not be made. Reason: \(error.localizedDescription)")
            return 1
        }

        let chosen = screens(samples).filter { screen in
            only.map { screen.name.localizedCaseInsensitiveContains($0) } ?? true
        }
        guard !chosen.isEmpty else {
            print("FAILED: no screen's name contains \"\(only ?? "")\".")
            return 64
        }
        for screen in chosen {
            await audit(screen)
        }
        if !headingLevelsReported && levelChecksSkipped > 0 {
            findings.append(Finding(level: .note, screen: "All screens", role: "AXHeading", path: "-",
                                    problem: "No heading reported a level, so \(levelChecksSkipped) level promises in the tester guide weren't checked. SwiftUI on macOS doesn't give .accessibilityHeading's level to assistive technology; VoiceOver finds these as headings, without a level."))
        }
        return writeReport()
    }

    // MARK: Screens

    func screens(_ s: Samples) -> [Screen] {
        let store = s.store
        let focus = s.focusLock
        func host<V: View>(_ view: V) -> AnyView {
            AnyView(view.environmentObject(store).environmentObject(focus))
        }
        // Section 5 of AVM-TESTER-GUIDE.md: the app title at level one, each
        // machine's name a heading in the table of machines, the chosen one's
        // controls (the first, at first) below it (2026-10-30), Status at
        // level three.
        var dashboard = [ExpectedHeading(text: "Accessible Virtual Machine", level: 1, source: "guide section 5: the app title, a level-one heading")]
        for config in store.configurations {
            dashboard.append(ExpectedHeading(text: config.name, level: 0, source: "guide section 5: each machine's name, a heading in the table"))
        }
        if let first = store.configurations.first {
            dashboard.append(ExpectedHeading(text: "Controls for \(first.name)", level: 3, source: "guide section 5: the chosen machine's controls, a level-three heading"))
        }
        dashboard.append(ExpectedHeading(text: "Status", level: 3, source: "guide section 5: Status, a level-three heading"))
        // Section 6: the Setup Wizard's title and Where to Store It.
        let wizard = [
            ExpectedHeading(text: "Setup Wizard", level: 0, source: "guide section 6: Setup Wizard is the title, a heading"),
            ExpectedHeading(text: "Where to Store It", level: 0, source: "guide section 6: Where to Store It is a heading"),
        ]
        func title(_ text: String) -> [ExpectedHeading] {
            [ExpectedHeading(text: text, level: 0, source: "every screen has a title heading to land on")]
        }
        return [
            Screen(name: "Dashboard", size: NSSize(width: 760, height: 900), headings: dashboard) { host(ContentView()) },
            Screen(name: "Setup Wizard", size: NSSize(width: 760, height: 1500), headings: wizard) { host(SetupView()) },
            Screen(name: "Setup Wizard, Windows ISO chosen", size: NSSize(width: 760, height: 2000), headings: wizard) {
                host(SetupView(auditInstaller: .windows))
            },
            Screen(name: "Setup Wizard, Ubuntu ISO chosen", size: NSSize(width: 760, height: 1500), headings: wizard) {
                host(SetupView(auditInstaller: .ubuntu))
            },
        ] + SettingsCategory.allCases.flatMap { category -> [Screen] in
            // Every category of Settings (2026-10-30), Windows's and Ubuntu's,
            // each a screen of its own: only the one showing is there to read.
            let name = category == .general ? "" : ", \(category.title)"
            return [
                Screen(name: "Windows Settings\(name)", size: NSSize(width: 760, height: 1400), headings: title("Settings: \(category.title)")) {
                    host(SettingsView(configuration: s.windows, isRunning: false, startCategory: category))
                },
                Screen(name: "Ubuntu Settings\(name)", size: NSSize(width: 760, height: 1400), headings: title("Settings: \(category.title)")) {
                    host(SettingsView(configuration: s.ubuntu, isRunning: false, startCategory: category))
                },
            ]
        } + [
            Screen(name: "Windows Settings, running", size: NSSize(width: 760, height: 1400), headings: title("Settings: General")) {
                host(SettingsView(configuration: s.windows, isRunning: true))
            },
            Screen(name: "New macOS Virtual Machine", size: NSSize(width: 640, height: 900), headings: title("New macOS Virtual Machine")) {
                host(MacSetupView())
            },
        ] + PreferencesCategory.allCases.map { [updater = AVMUpdater(starting: false)] category -> Screen in
            // Every category of AVM's own Settings (2026-10-30).
            let name = category == .general ? "" : ", \(category.title)"
            return Screen(name: "AVM Settings\(name)", size: NSSize(width: 560, height: 580),
                          headings: title("AVM Settings: \(category.title)")) {
                host(AppPreferencesView(startCategory: category).environmentObject(updater))
            }
        } + SettingsCategory.allCases.map { category -> Screen in
            // Every category of a macOS machine's Settings too (2026-10-30).
            let name = category == .general ? "" : ", \(category.title)"
            return Screen(name: "macOS Settings\(name)", size: NSSize(width: 640, height: 900),
                          headings: title("Settings for \(s.mac.name): \(category.title)")) {
                host(MacSettingsView(configuration: s.mac, isRunning: false, startCategory: category))
            }
        } + [
            Screen(name: "Download Windows 11 for ARM", size: NSSize(width: 600, height: 500), headings: title("Download Windows 11 for ARM")) {
                host(ISODownloadView(assistant: WindowsISODownloader(), automatic: WindowsAutoDownloader()) { _ in })
            },
            // Download Linux (2026-10-30, LinuxISODownload.swift).
            Screen(name: "Download Linux", size: NSSize(width: 600, height: 500), headings: title("Download Linux")) {
                host(LinuxDownloadView(downloader: LinuxISODownloader()))
            },
            Screen(name: "Reclaim Disk Space", size: NSSize(width: 600, height: 600), headings: title("Reclaim Disk Space")) {
                host(ReclaimView())
            },
            Screen(name: "Attach USB Device", size: NSSize(width: 600, height: 500), headings: title("Attach USB Device")) {
                host(USBDevicePickerView(mode: .attach, devices: s.usbDevices))
            },
            // What's New after an update (2026-10-30, AVMUpdater.swift).
            Screen(name: "What's New", size: WhatsNewView.size, headings: title("What's New in AVM")) {
                host(WhatsNewView(title: "What's New in AVM", notes: ReleaseNotes.recent, close: {}))
            },
        ]
    }

    // MARK: One screen

    nonisolated(unsafe) static var pictures: URL?
    nonisolated(unsafe) static var dark = false

    /// The window as an image, in the appearance it has now.
    func picture(_ window: NSWindow, _ hosting: NSView, _ screen: Screen, _ appearance: String) {
        guard let folder = Self.pictures,
              let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        // The view draws on a clear backdrop; on screen the window frame
        // paints the background behind it. Paint it here too, or dark mode
        // comes out as white text on white.
        let pixels = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            pixels.fill()
        }
        // Over it, not instead of it: draw(in:) alone copies the clear
        // corners in.
        rep.draw(in: pixels, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = out.representation(using: .png, properties: [:]) else { return }
        let name = screen.name.replacingOccurrences(of: "/", with: "-") + " (\(appearance)).png"
        try? png.write(to: folder.appendingPathComponent(name))
    }

    func audit(_ screen: Screen) async {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -40_000, y: -40_000), size: screen.size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "AVM audit: \(screen.name)"
        let hosting = NSHostingView(rootView: screen.make())
        hosting.frame = NSRect(origin: .zero, size: screen.size)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -40_000, y: -40_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        // Lets onAppear, .task (restore points come from qemu-img) and the
        // delayed first-field focus run, and SwiftUI settle.
        await turns(seconds: 2.0)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await turns(seconds: 0.3)

        var nodes = walk(window)
        // SwiftUI fills its tree a moment after the assistive-technology
        // signal (see the header); a screen gets up to 3 more seconds.
        for _ in 0..<10 where !nodes.contains(where: \.isControl) {
            await turns(seconds: 0.3)
            nodes = walk(window)
        }
        treeDump.append("=== \(screen.name)")
        treeDump.append(contentsOf: nodes.map { String(repeating: "  ", count: $0.depth) + $0.describe + "    @ " + $0.path })

        if nodes.contains(where: \.isControl) {
            check(screen, nodes: nodes)
            checkKeyboard(screen, nodes: nodes)
        } else {
            findings.append(Finding(level: .error, screen: screen.name, role: "AXWindow", path: "window",
                                    problem: "Not checked: SwiftUI gave this window no controls to read, even after AXEnhancedUserInterface was set. Look at it with VoiceOver instead."))
        }
        if Self.pictures != nil {
            window.displayIfNeeded()
            picture(window, hosting, screen, Self.dark ? "dark" : "light")
        }
        let errors = findings.filter { $0.screen == screen.name && $0.level == .error }.count
        let warnings = findings.filter { $0.screen == screen.name && $0.level == .warning }.count
        let line = "\(screen.name): \(nodes.count) elements, \(nodes.filter(\.isControl).count) controls, \(errors) errors, \(warnings) warnings"
        summary.append(line)
        print(line)
        fflush(stdout)
        window.orderOut(nil)
        window.close()
        await turns(seconds: 0.1)
    }

    /// Lets the main run loop (and so SwiftUI and main-actor tasks) run.
    func turns(seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Walking the tree

    func walk(_ window: NSWindow) -> [AuditNode] {
        var nodes: [AuditNode] = []
        var visited = Set<ObjectIdentifier>()
        // From the content view down: the title bar's own buttons are
        // AppKit's, and the real AVM window has them anyway.
        let roots = (window.contentView?.accessibilityChildren() ?? []).map { $0 as AnyObject }
        for (i, child) in roots.enumerated() {
            walk(child, path: "window", index: i, depth: 0, into: &nodes, visited: &visited)
        }
        return nodes
    }

    private func walk(_ object: AnyObject, path: String, index: Int, depth: Int,
                      into nodes: inout [AuditNode], visited: inout Set<ObjectIdentifier>) {
        guard depth < 60, visited.insert(ObjectIdentifier(object)).inserted else { return }
        let element = AXElementReader(object)
        let role = element.string("AXRole")
        let subrole = element.string("AXSubrole")
        // AppKit's own parts of a scroll bar or stepper: VoiceOver names
        // them itself, and they are the same in every app.
        if role == "AXScrollBar" || Self.standardParts.contains(subrole) { return }
        var here = path
        var childDepth = depth
        if element.isElement && !role.isEmpty {
            var node = AuditNode(
                role: role,
                subrole: subrole,
                label: element.string("AXDescription"),
                title: element.string("AXTitle"),
                value: Self.text(element.object("AXValue")),
                placeholder: element.string("AXPlaceholderValue"),
                hint: element.string("AXHelp"),
                roleDescription: element.string("AXRoleDescription"),
                enabled: element.bool("AXEnabled") ?? true,
                headingLevel: 0,
                path: "",
                depth: depth,
                focusable: element.focusSettable.map { $0 || (object as? NSView)?.canBecomeKeyView == true })
            if role == "AXHeading" {
                node.headingLevel = Int(node.value) ?? 0
                node.value = ""
                if node.headingLevel > 0 { headingLevelsReported = true }
            }
            if node.name.isEmpty, let titleObject = element.object("AXTitleUIElement") {
                let title = AXElementReader(titleObject as AnyObject)
                node.title = title.string("AXDescription")
                if node.title.isEmpty { node.title = Self.text(title.object("AXValue")) }
            }
            here = "\(path) > \(Self.short(role))[\(index)]\(node.text.isEmpty ? "" : " \"\(node.text.prefix(40))\"")"
            node.path = here
            nodes.append(node)
            childDepth = depth + 1
        }
        let children = (element.object("AXChildren") as? [Any] ?? []).map { $0 as AnyObject }
        for (i, child) in children.enumerated() {
            walk(child, path: here, index: i, depth: childDepth, into: &nodes, visited: &visited)
        }
    }

    static let standardParts: Set<String> = [
        "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage",
    ]

    static func text(_ value: Any?) -> String {
        switch value {
        case nil: return ""
        case let s as String: return s
        case let a as NSAttributedString: return a.string
        case let n as NSNumber: return n.stringValue
        case let v?: return "\(v)"
        }
    }

    static func short(_ role: String) -> String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }

    // MARK: Checks

    func check(_ screen: Screen, nodes: [AuditNode]) {
        func add(_ level: Finding.Level, _ n: AuditNode, _ problem: String) {
            findings.append(Finding(level: level, screen: screen.name, role: n.role, path: n.path, problem: problem))
        }

        for n in nodes where n.isControl {
            if n.name.isEmpty {
                if n.isTextEntry && !n.placeholder.isEmpty {
                    add(.warning, n, "Text field named only by its placeholder (\"\(n.placeholder)\"); VoiceOver may not say it once something is typed. Give it an accessibilityLabel.")
                } else {
                    add(.error, n, "No label or title: VoiceOver says only \"\(spokenRole(n.role))\". Give it an accessibilityLabel.")
                }
            } else if let repeated = Self.repeatedHalf(n.name) {
                add(.warning, n, "VoiceOver says \"\(repeated)\" twice (\"\(n.name)\"): SwiftUI speaks a control's hidden title and then its accessibilityLabel. Keep one.")
            }
        }

        // A stepper or radio group whose title SwiftUI also shows as text
        // just before it (a Stepper or Picker whose label isn't hidden):
        // VoiceOver meets the same words twice in a row.
        for (i, n) in nodes.enumerated() where i > 0 && (n.role == "AXIncrementor" || n.role == "AXRadioGroup") {
            let before = nodes[i - 1]
            if before.role == "AXStaticText", !n.name.isEmpty,
               before.text.caseInsensitiveCompare(n.name) == .orderedSame {
                add(.warning, n, "The text just before it says \"\(before.text)\" too, so VoiceOver says it twice in a row. Hide one from VoiceOver, or give the \(spokenRole(n.role)) a shorter label.")
            }
        }

        for n in nodes where n.role == "AXImage" && n.name.isEmpty {
            add(.error, n, "Image with no label. Label it, or hide it with accessibilityHidden(true) if it is decoration.")
        }

        // Same label on several controls of one kind: VoiceOver can't tell
        // them apart (the rows' "Delete" without the machine's name).
        var groups: [String: [AuditNode]] = [:]
        for n in nodes where n.isControl && !n.name.isEmpty {
            groups["\(n.role)\u{0}\(n.name.lowercased())", default: []].append(n)
        }
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) where group.count > 1 {
            for n in group {
                add(.error, n, "\(group.count) \(spokenRole(n.role))s are all called \"\(n.name)\"; VoiceOver can't tell them apart. Put what each one acts on in its label, such as the machine's name.")
            }
        }

        // Headings.
        let headings = nodes.filter(\.isHeading)
        for expected in screen.headings {
            let matches = headings.filter { expected.text.isEmpty || $0.text.caseInsensitiveCompare(expected.text) == .orderedSame }
            if matches.isEmpty {
                let asText = nodes.first { !expected.text.isEmpty && $0.text.caseInsensitiveCompare(expected.text) == .orderedSame }
                findings.append(Finding(level: .error, screen: screen.name, role: asText?.role ?? "AXHeading",
                                        path: asText?.path ?? "-",
                                        problem: "Missing heading \(expected.text.isEmpty ? "(level \(expected.level))" : "\"\(expected.text)\"")\(asText != nil ? ": the text is there, but not as a heading" : ""). Expected by \(expected.source)."))
            } else if expected.level > 0 && !matches.contains(where: { $0.headingLevel == expected.level }) {
                if matches.allSatisfy({ $0.headingLevel == 0 }) {
                    levelChecksSkipped += 1   // see headingLevelsReported
                } else {
                    let n = matches[0]
                    add(.error, n, "Heading \"\(n.text)\" is at level \(n.headingLevel); \(expected.source) says level \(expected.level).")
                }
            }
        }
    }

    /// "Privacy" for "Privacy, Privacy", or "Memory" for "Memory, Memory
    /// in gigabytes": a title SwiftUI speaks, then a label that starts
    /// with the same words. nil when the label doesn't repeat itself.
    static func repeatedHalf(_ label: String) -> String? {
        let parts = label.components(separatedBy: ", ")
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return parts[1].lowercased().hasPrefix(parts[0].lowercased()) ? parts[0] : nil
    }

    func spokenRole(_ role: String) -> String {
        switch role {
        case "AXButton": return "button"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio button"
        case "AXRadioGroup": return "radio group"
        case "AXTextField": return "text field"
        case "AXTextArea": return "text area"
        case "AXPopUpButton": return "pop-up button"
        case "AXComboBox": return "combo box"
        case "AXSlider": return "slider"
        case "AXIncrementor": return "stepper"
        case "AXLink": return "link"
        default: return Self.short(role).lowercased()
        }
    }

    // MARK: Keyboard

    /// See KEYBOARD in the header.
    func checkKeyboard(_ screen: Screen, nodes: [AuditNode]) {
        for n in nodes where n.isControl && n.enabled && n.focusable == false {
            // A radio group takes focus through its buttons.
            if n.role == "AXRadioGroup" { continue }
            guard keyboardNavigationOn || n.isTextEntry else { continue }
            findings.append(Finding(level: .warning, screen: screen.name, role: n.role, path: n.path,
                                    problem: "Keyboard focus can't be put on this \(spokenRole(n.role)): it can't become the key view and its AXFocused can't be set, so Tab skips it."))
        }
    }

    // MARK: Report

    func writeReport() -> Int32 {
        let errors = findings.filter { $0.level == .error }
        let warnings = findings.filter { $0.level == .warning }
        var lines = [
            "AVM accessibility audit, \(ISO8601DateFormatter().string(from: Date()))",
            "AVM \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")), \(Bundle.main.bundlePath)",
            "Keyboard navigation: \(keyboardNavigationOn ? "on" : "off").",
            "\(errors.count) errors, \(warnings.count) warnings.",
            "Columns, tab-separated: level, screen, role, path, problem.",
            "",
        ]
        lines += summary.map { "# \($0)" }
        lines.append("")
        lines += findings.map(\.line)
        let report = out.appendingPathComponent("accessibility-report.txt")
        let tree = out.appendingPathComponent("accessibility-tree.txt")
        do {
            try lines.joined(separator: "\n").appending("\n").write(to: report, atomically: true, encoding: .utf8)
            try treeDump.joined(separator: "\n").appending("\n").write(to: tree, atomically: true, encoding: .utf8)
        } catch {
            print("FAILED: the report could not be written. Reason: \(error.localizedDescription)")
            return 1
        }
        print("")
        print("\(errors.count) errors, \(warnings.count) warnings, across \(summary.count) screens.")
        print("Report: \(report.path)")
        print("Tree:   \(tree.path)")
        return errors.isEmpty ? 0 : 1
    }
}

// MARK: - Reading any accessibility object

/// The NSAccessibility methods, all optional, so they can be asked of any
/// object. SwiftUI's own nodes (AccessibilityNode) answer them without
/// declaring NSAccessibility conformance, so `as? NSAccessibilityProtocol`
/// misses them (measured 2026-10-26); this asks each method only when the
/// object has it, and falls back to the older attribute-name API.
@objc private protocol AXInformal {
    @objc optional func accessibilityRole() -> String?
    @objc optional func accessibilitySubrole() -> String?
    @objc optional func accessibilityLabel() -> String?
    @objc optional func accessibilityTitle() -> String?
    @objc optional func accessibilityValue() -> Any?
    @objc optional func accessibilityPlaceholderValue() -> String?
    @objc optional func accessibilityHelp() -> String?
    @objc optional func accessibilityRoleDescription() -> String?
    @objc optional func accessibilityChildren() -> [Any]?
    @objc optional func accessibilityTitleUIElement() -> Any?
    @objc optional func isAccessibilityElement() -> Bool
    @objc optional func isAccessibilityEnabled() -> Bool
    @objc optional func accessibilityAttributeValue(_ attribute: String) -> Any?
    @objc optional func accessibilityIsIgnored() -> Bool
    @objc optional func accessibilityIsAttributeSettable(_ attribute: String) -> Bool
    @objc optional func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool
}

@MainActor
private struct AXElementReader {
    let raw: AXInformal

    init(_ object: AnyObject) {
        // An @objc protocol existential is the object pointer itself.
        raw = unsafeBitCast(object, to: AXInformal.self)
    }

    private func legacy(_ attribute: String) -> Any? {
        raw.accessibilityAttributeValue?(attribute) ?? nil
    }

    func object(_ attribute: String) -> Any? {
        let direct: Any?? = {
            switch attribute {
            case "AXValue": return raw.accessibilityValue?()
            case "AXChildren": return raw.accessibilityChildren?().map { $0 as Any }
            case "AXTitleUIElement": return raw.accessibilityTitleUIElement?()
            default: return nil
            }
        }()
        if let direct, let value = direct { return value }
        return legacy(attribute)
    }

    func string(_ attribute: String) -> String {
        let direct: String?? = {
            switch attribute {
            case "AXRole": return raw.accessibilityRole?()
            case "AXSubrole": return raw.accessibilitySubrole?()
            case "AXDescription": return raw.accessibilityLabel?()
            case "AXTitle": return raw.accessibilityTitle?()
            case "AXPlaceholderValue": return raw.accessibilityPlaceholderValue?()
            case "AXHelp": return raw.accessibilityHelp?()
            case "AXRoleDescription": return raw.accessibilityRoleDescription?()
            default: return nil
            }
        }()
        if let direct, let value = direct { return value }
        return Auditor.text(legacy(attribute))
    }

    func bool(_ attribute: String) -> Bool? {
        if attribute == "AXEnabled", let v = raw.isAccessibilityEnabled?() { return v }
        return (legacy(attribute) as? NSNumber)?.boolValue
    }

    /// Whether AXFocused can be set, as the AX API's
    /// AXUIElementIsAttributeSettable asks it.
    var focusSettable: Bool? {
        if let v = raw.accessibilityIsAttributeSettable?("AXFocused") { return v }
        return raw.isAccessibilitySelectorAllowed?(Selector(("setAccessibilityFocused:")))
    }

    var isElement: Bool {
        if let v = raw.isAccessibilityElement?() { return v }
        if let ignored = raw.accessibilityIsIgnored?() { return !ignored }
        return true
    }
}

// MARK: - Sample machines

/// The machines the screens are opened with, all in the audit's temporary
/// support folder: a Windows one with a shared folder, two remembered USB
/// devices and two restore points (real qcow2 snapshots, made with the
/// bundled qemu-img, as Settings reads them); an Ubuntu one; a macOS one
/// with two restore points; and two leftover folders for Reclaim.
@MainActor
private struct Samples {
    let store: VMStore
    let focusLock: FocusLockManager
    let windows: VMConfiguration
    let ubuntu: VMConfiguration
    let mac: VMConfiguration
    let usbDevices: [AVMUSBDeviceIdentity]

    static func make(in scratch: URL) async throws -> Samples {
        let fm = FileManager.default
        let store = VMStore()
        guard store.configurations.isEmpty else {
            throw NSError(domain: "AVM.Audit", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The audit's machine list wasn't empty, so it isn't the sample one."])
        }

        let shared = scratch.appendingPathComponent("Shared with Windows", isDirectory: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        var windows = VMConfiguration(name: "Work PC", cpuCount: 4, ramSizeGB: 8, diskSizeGB: 64,
                                      sharedFolderPath: shared.path,
                                      usbRememberedDevices: [
                                          RememberedUSBDevice(name: "Focus 40 Blue", vendorID: 0x0F4E, productID: 0x0114,
                                                              serialNumber: "AUDIT1", decision: "windows"),
                                          RememberedUSBDevice(name: "SanDisk Ultra", vendorID: 0x0781, productID: 0x5581,
                                                              serialNumber: "AUDIT2", decision: "mac"),
                                      ],
                                      guestOSName: GuestOS.windows.rawValue,
                                      windowsEditionName: WindowsEdition.pro.rawValue,
                                      windowsScreenReaderNames: [ScreenReader.nvda.rawValue])
        let windowsFolder = try windows.directoryURL()
        try fm.createDirectory(at: windowsFolder, withIntermediateDirectories: true)
        windows.diskImagePath = windowsFolder.appendingPathComponent("disk.qcow2").path
        // Remote Desktop on, and saved with open apps (2026-10-28): the
        // controls that only appear then are in the audit too.
        windows.remoteDesktopUser = "tester"
        windows.remoteDesktopPort = 3389
        try "Saved\n".write(to: windowsFolder.appendingPathComponent(QEMUSavedState.hintFile), atomically: true, encoding: .utf8)
        try makeQcow2(at: windowsFolder.appendingPathComponent("disk.qcow2"))
        _ = try await RestorePoints.create(vmDirectory: windowsFolder, label: "Fresh install", secureBoot: false)
        try? await Task.sleep(nanoseconds: 5_000_000)   // restore point tags are milliseconds
        _ = try await RestorePoints.create(vmDirectory: windowsFolder, label: "Before the October update", secureBoot: false)
        store.save(windows)

        var ubuntu = VMConfiguration(name: "Ubuntu Desktop", cpuCount: 4, ramSizeGB: 8, diskSizeGB: 64,
                                     guestOSName: GuestOS.ubuntu.rawValue)
        ubuntu.isTemplate = true   // a template's row has its own button (2026-10-28)
        let ubuntuFolder = try ubuntu.directoryURL()
        try fm.createDirectory(at: ubuntuFolder, withIntermediateDirectories: true)
        ubuntu.diskImagePath = ubuntuFolder.appendingPathComponent("disk.qcow2").path
        store.save(ubuntu)

        var mac = VMConfiguration(name: "Test Mac", cpuCount: 4, ramSizeGB: 8, diskSizeGB: 80,
                                  guestOSName: GuestOS.macOS.rawValue)
        let files = MacGuestFiles(folder: try mac.directoryURL())
        mac.diskImagePath = files.disk.path
        for (index, name) in ["Fresh install", "Before trying Xcode"].enumerated() {
            let point = files.restorePoints.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: point, withIntermediateDirectories: true)
            let info: [String: Any] = ["name": name, "date": Date().timeIntervalSince1970 - Double(86_400 * (2 - index))]
            try JSONSerialization.data(withJSONObject: info).write(to: point.appendingPathComponent("point.json"))
        }
        store.save(mac)

        // Two leftover folders, as an old AVM's delete left them.
        let container = try VMConfiguration.defaultVMsContainer()
        for size in [3_000_000, 1_500_000] {
            let orphan = container.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data(count: size).write(to: orphan.appendingPathComponent("disk.qcow2"))
        }

        let devices = [
            AVMUSBDeviceIdentity(vendorID: 0x0F4E, productID: 0x0114, busNumber: 1, deviceAddress: 3,
                                 serialNumber: "AUDIT1", productString: "Focus 40 Blue"),
            AVMUSBDeviceIdentity(vendorID: 0x0781, productID: 0x5581, busNumber: 1, deviceAddress: 4,
                                 serialNumber: "AUDIT2", productString: "SanDisk Ultra"),
            AVMUSBDeviceIdentity(vendorID: 0x1234, productID: 0x0001, busNumber: 2, deviceAddress: 1,
                                 serialNumber: nil, productString: ""),
        ]
        return Samples(store: store, focusLock: FocusLockManager(), windows: windows, ubuntu: ubuntu, mac: mac,
                       usbDevices: devices)
    }

    /// A small, empty qcow2 disk made with AVM's own qemu-img.
    private static func makeQcow2(at url: URL) throws {
        guard let tool = Bundle.main.resourceURL?.appendingPathComponent("qemu-img"),
              FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw NSError(domain: "AVM.Audit", code: 2, userInfo: [NSLocalizedDescriptionKey: "qemu-img is missing from this AVM build."])
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["create", "-q", "-f", "qcow2", url.path, "1G"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "AVM.Audit", code: 3, userInfo: [NSLocalizedDescriptionKey: "qemu-img couldn't make the sample disk."])
        }
    }
}
