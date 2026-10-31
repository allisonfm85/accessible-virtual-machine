// AppPreferencesView.swift
// AVM — Accessible Virtual Machine
//
// AVM's own Settings (2026-10-30, the user's request): Command-Comma from
// any AVM window, the list or a machine's, as every Mac app has it. What
// belongs to AVM as a whole lives here; what belongs to one machine stays
// in that machine's Settings (Command-Option-Comma on the list).
// Categories in the same toolbar as a machine's Settings
// (SettingsCategoryBar), so VoiceOver meets one way of moving around both.

import AppKit
import Combine
import SwiftUI

enum PreferencesCategory: String, CaseIterable, Identifiable, SettingsCategoryItem {
    case general, startup, keyboard, devices

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .startup: return "Startup and Background"
        case .keyboard: return "Keyboard"
        case .devices: return "Devices"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .startup: return "power"
        case .keyboard: return "keyboard"
        case .devices: return "cable.connector"
        }
    }
}

/// Which category Settings shows, so a menu item or button can open it on
/// one.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    @Published var category: PreferencesCategory = .general

    /// Opens AVM's Settings on a category, from the list's buttons and
    /// the menus. Through the AVM menu's own Settings item: SwiftUI's
    /// openSettings needs macOS 14, and showSettingsWindow: does nothing
    /// from macOS 14 on.
    static func open(_ category: PreferencesCategory? = nil) {
        if let category { shared.category = category }
        NSApp.activate(ignoringOtherApps: true)
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else {
            AVMLog.write("AVM: Settings — the AVM menu has no Settings item")
            return
        }
        appMenu.performActionForItem(at: index)
    }
}

struct AppPreferencesView: View {
    @EnvironmentObject var vmStore: VMStore
    @EnvironmentObject var updater: AVMUpdater
    @ObservedObject private var preferences = AppPreferences.shared
    /// The category it opens on, for the accessibility audit.
    var startCategory: PreferencesCategory?

    @State private var capsLockKey = CapsLockRemapper.shared.isEnabled

    private var category: PreferencesCategory { startCategory ?? preferences.category }

    var body: some View {
        VStack(spacing: 0) {
            SettingsCategoryBar(selection: Binding(get: { category }, set: { preferences.category = $0 }),
                                categories: PreferencesCategory.allCases)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(category.title)
                        .font(.title2)
                        .accessibilityLabel("AVM Settings: \(category.title)")
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityHeading(.h1)
                    switch category {
                    case .general: general
                    case .startup: BackgroundSettingsControls()
                    case .keyboard: keyboard
                    case .devices: devices
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(width: 560, height: 520)
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.checksAutomatically },
                set: { updater.checksAutomatically = $0 }))
            Text("AVM looks for a new version when it opens and once a day, and asks before installing one.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Check for Updates Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Button("What's New") { ReleaseNotes.showRecent() }
                    .accessibilityHint("Shows what changed in this version of AVM and the two before it")
            }
            Text("Each virtual machine's own settings, such as its memory, devices and shared folder, are in its Settings: select it in the list and press Command-Option-Comma.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Keyboard

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Use Caps Lock as the screen reader key in Windows", isOn: Binding(
                get: { capsLockKey },
                set: { on in
                    capsLockKey = on
                    UserDefaults.standard.set(on, forKey: CapsLockRemapper.enabledKey)
                    AVMLog.write("AVM: Settings — Caps Lock as the screen reader key \(on ? "on" : "off")")
                }))
            Text("NVDA, JAWS and Narrator can use Caps Lock as their key. A Mac sends Caps Lock only when it's pressed and let go, so while your keyboard is in Windows, AVM has the Mac send it as a key Windows can hold. Your Mac's Caps Lock is back as it was when your keyboard returns to the Mac. Changes take effect the next time you go into Windows.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("To return to the Mac from Windows, press Control-Command-Escape. A second keyboard just for Windows is chosen in a machine's Settings, under Devices.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Devices

    private var devices: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("Restart USB Helper") {
                Task { await USBRedirectController.shared.restartHelper() }
            }
            .accessibilityHint("Returns USB devices to the Mac and restarts the part of AVM that sends them to a virtual machine. Use it if a device won't go across.")
            Text("The USB helper is the part of AVM that sends USB devices, Bluetooth devices and a keyboard for Windows to a virtual machine. If a device won't go across, or stays with Windows when it shouldn't, restart it here.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Which devices a machine uses is in its Settings, under Devices.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
