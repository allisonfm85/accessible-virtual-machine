// MachineDisplays.swift
// AVM — Accessible Virtual Machine
//
// A display for a machine (2026-10-28, tester idea, "like the keyboard for
// Windows"). In a machine's Settings, Monitor: the monitor its window always
// opens on, filling it, every time it starts, as the keyboard for Windows
// is the keyboard that always belongs to it. Remembered by macOS's lasting
// id for the display, so it's the same monitor after a restart or a
// different plug. When it isn't connected, the window opens on another
// display, that's said, and it moves to the chosen one as soon as it's
// connected again. With no display chosen, Show Machines on the Second
// Display (BackgroundMode.swift) decides, then wherever it was last.

import AppKit

@MainActor
enum MachineDisplays {

    struct Display: Identifiable {
        let id: String
        let name: String
        let hasMenuBar: Bool
        let screen: NSScreen

        /// For the Settings pop-up: says which one has the menu bar.
        var choiceName: String { hasMenuBar ? "\(name) (with the menu bar)" : name }
    }

    /// The displays connected now; the one with the menu bar first.
    static var connected: [Display] {
        let screens = NSScreen.screens
        return screens.compactMap { screen in
            guard let id = lastingID(of: screen) else { return nil }
            return Display(id: id, name: screen.localizedName, hasMenuBar: screen == screens.first, screen: screen)
        }
    }

    /// macOS's id for a display that stays the same across restarts.
    static func lastingID(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The chosen display, when it's connected.
    static func chosenScreen(_ config: VMConfiguration) -> NSScreen? {
        guard let id = config.displayID else { return nil }
        return connected.first { $0.id == id }?.screen
    }

    /// Where the machine's window goes: its own display, else the second
    /// display when that's chosen for every machine.
    static func screen(for config: VMConfiguration) -> NSScreen? {
        if let screen = chosenScreen(config) { return screen }
        if BackgroundMode.shared.useSecondDisplay { return BackgroundMode.secondDisplay }
        return nil
    }

    /// A machine's window opening: onto its display, filling it. Says so
    /// when its own display isn't connected.
    static func placeOpening(_ window: NSWindow, for config: VMConfiguration) {
        if let screen = screen(for: config) {
            fill(window, on: screen)
        }
        if config.displayID != nil, chosenScreen(config) == nil {
            let display = config.displayName ?? "Its monitor"
            AVMLog.write("AVM: \(config.name)'s monitor isn't connected; opening elsewhere")
            Announcer.shared.announce("\(display) isn't connected, so \(config.name) opened on another monitor. It moves to \(display) when you connect it.", tone: .info)
        }
    }

    /// The displays changed (one plugged in or out): a machine whose own
    /// display is back moves to it. True when it moved.
    @discardableResult
    static func displaysChanged(_ window: NSWindow, for config: VMConfiguration) -> Bool {
        guard let screen = chosenScreen(config), window.screen != screen else { return false }
        fill(window, on: screen)
        AVMLog.write("AVM: \(config.name) moved to its display")
        Announcer.shared.announce("\(config.name) moved to \(screen.localizedName).", tone: .info)
        return true
    }

    static func fill(_ window: NSWindow, on screen: NSScreen) {
        guard window.frame != screen.visibleFrame else { return }
        window.setFrame(screen.visibleFrame, display: true)
    }
}
