// Tour.swift
// AVM — Accessible Virtual Machine
//
// Take the AVM Tour (2026-10-31, the user's request): Help > Take the AVM
// Tour opens a small window that walks a new user through AVM one step at
// a time, each step read out as it comes, with something to try before
// going on. The demo script and the skit testers heard showed the shape:
// short steps, the keys said in words, a pause to try each one. Next and
// Back move between steps; the window can be closed at any time, and the
// tour starts again from the Help menu.

import AppKit
import SwiftUI

struct TourStep {
    let title: String
    let text: String
    let tryIt: String?
}

@MainActor
enum Tour {
    static let steps: [TourStep] = [
        TourStep(title: "Welcome",
                 text: "AVM runs Windows, Linux and macOS on your Mac, and everything it does talks through VoiceOver. This tour takes about ten minutes. Press Next to go on, Back to hear a step again, or close the window to stop; the tour is in the Help menu whenever you want it.",
                 tryIt: nil),
        TourStep(title: "Your machines",
                 text: "Command-Shift-L opens the Virtual Machines list. Each machine's name is a heading, so VO-Command-H moves from one to the next.",
                 tryIt: "Press Command-Shift-L, then come back to this window with Command-Grave, the key above Tab."),
        TourStep(title: "Making a machine",
                 text: "In the list, Command-S opens the Setup Wizard. Download Windows 11 gets Windows from Microsoft; Download Linux offers Ubuntu, Debian, Fedora, Kali Linux, AlmaLinux, Rocky Linux and openSUSE. AVM installs it and answers every question, and the screen reader is on when it's done.",
                 tryIt: nil),
        TourStep(title: "Starting, and the keyboard",
                 text: "Select a machine and press Command-Shift-S to start it. Command-Shift-E sends your keyboard into it. Control-Command-Escape brings it back to the Mac, from anywhere. A rising sound means the keyboard went in, a falling one that it came back.",
                 tryIt: "Start a machine, press Command-Shift-E, then Control-Command-Escape."),
        TourStep(title: "A keyboard just for Windows",
                 text: "A second keyboard, USB or Bluetooth, can type only into Windows. Choose it in the Windows machine's Settings, under Devices, Keyboard for Windows. Your Mac's keyboard stays with the Mac and VoiceOver, and Windows stays out of Command-Tab.",
                 tryIt: nil),
        TourStep(title: "Hearing the screen",
                 text: "Command-Shift-O reads the machine's whole screen aloud at any time, such as during Setup or a restart, when no screen reader is running, and Command-Option-Shift-O describes what it looks like. Command-Shift-I says how the machine is doing.",
                 tryIt: "With a machine running, press Command-Shift-O."),
        TourStep(title: "Files, folders and the clipboard",
                 text: "Command-Shift-F sends a file from the Mac to the machine's Downloads folder; in Finder, Send to Virtual Machine in Quick Actions does the same. Command-Shift-V types the Mac's clipboard into the machine, even where pasting doesn't work. A shared folder, set in the machine's Settings under Sharing, is a folder on the Mac and in the machine at once.",
                 tryIt: nil),
        TourStep(title: "Braille and other devices",
                 text: "Command-Shift-U sends a USB device to the machine, such as a braille display, and Command-Shift-M gives devices back to the Mac. Command-Shift-B does the same for Bluetooth. The machine can also use your Mac's printers, camera and microphone, set in its Settings.",
                 tryIt: nil),
        TourStep(title: "When things go wrong",
                 text: "Restore points, in a machine's Settings under Startup and Recovery, take it back to an earlier moment. If a machine stops answering, Command-Shift-R resets it after asking. Report a Problem, in the Help menu, sends AVM's log to the AVM team.",
                 tryIt: nil),
        TourStep(title: "Ready when you are",
                 text: "Turn on Open AVM When You Log In, in AVM's Settings, and Start When AVM Opens on a machine's row, and that machine is up and talking when your Mac starts. That's the tour. Enjoy AVM.",
                 tryIt: nil),
    ]

    private static var window: NSWindow?

    static func show() {
        window?.close()
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "AVM Tour"
        panel.isReleasedWhenClosed = false
        // Closing it stops the system voice too; with VoiceOver off there
        // was no stopping a long step (2026-11-01 audit).
        panel.contentView = NSHostingView(rootView: TourView {
            Announcer.shared.stopSystemVoice()
            window?.close()
        })
        panel.center()
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        say(0)
    }

    /// Each step read out as it comes, through VoiceOver as AVM's other lines are.
    static func say(_ index: Int) {
        let step = steps[index]
        Announcer.shared.announce("Step \(index + 1) of \(steps.count): \(step.title). \(step.text)" + (step.tryIt.map { " Try it: \($0)" } ?? ""), tone: .info)
    }
}

struct TourView: View {
    let close: () -> Void
    @State private var index = 0

    var body: some View {
        let step = Tour.steps[index]
        VStack(alignment: .leading, spacing: 14) {
            Text("Step \(index + 1) of \(Tour.steps.count): \(step.title)")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
            Text(step.text)
                .fixedSize(horizontal: false, vertical: true)
            if let tryIt = step.tryIt {
                Text("Try it: \(tryIt)")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack {
                Button("Back") { move(-1) }
                    .disabled(index == 0)
                Spacer()
                Button("Close Tour", action: close)
                if index < Tour.steps.count - 1 {
                    Button("Next") { move(1) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 360)
    }

    private func move(_ by: Int) {
        index = max(0, min(Tour.steps.count - 1, index + by))
        Tour.say(index)
    }
}
