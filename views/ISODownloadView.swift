// ISODownloadView.swift
// AVM — Accessible Virtual Machine
//
// The setup wizard's "Download Windows 11 for ARM…" sheet (2026-10-25,
// roadmap item 9). The download happens on Microsoft's page in the user's
// browser; WindowsISODownloader watches for it, speaks its progress, and
// checks the result. This sheet is the controls for that. Same rules as
// the rest of AVM: honestly labelled controls, a heading to land on,
// Escape and Command-Return for the two main buttons.

import SwiftUI
import AppKit

struct ISODownloadView: View {

    /// The setup wizard's, so watching goes on after this window closes
    /// (2026-10-27): it used to belong to this window and stop with it.
    @ObservedObject var assistant: WindowsISODownloader
    /// The download with no web page (2026-10-30, WindowsAutoDownload.swift),
    /// the wizard's too.
    @ObservedObject var automatic: WindowsAutoDownloader
    /// Called with the downloaded ISO when the user chooses to use it.
    let onFinished: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Microsoft's page instead, chosen with its button (2026-10-30).
    @State private var usingBrowser = false

    var body: some View {
        if usingBrowser || assistant.phase != .idle {
            browserBody
        } else {
            automaticBody
        }
    }

    // MARK: Automatic (2026-10-30)

    /// No web page: AVM gets Windows from Microsoft's servers itself.
    private var automaticBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Download Windows 11 for ARM")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Text("AVM gets Windows 11 for ARM straight from Microsoft's servers, the way Microsoft's own Media Creation Tool does, in your Mac's language: there's no web page to use. It says how far along it is every 10 percent, checks the download against Microsoft's checksum, makes it into an installer and chooses it for you. It's about 4.5 gigabytes, and needs about 20 gigabytes free while it works.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            automaticStatus

            HStack {
                Spacer()
                automaticButtons
            }
        }
        .padding(28)
        .frame(minWidth: 460)
    }

    @ViewBuilder
    private var automaticStatus: some View {
        switch automatic.phase {
        case .idle:
            EmptyView()
        case .finding, .downloading, .verifying, .building:
            HStack(spacing: 10) {
                if automatic.phase == .downloading, automatic.expected > 0 {
                    ProgressView(value: Double(automatic.received), total: Double(automatic.expected))
                        .frame(width: 160)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(automatic.spokenProgress)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Button("Speak Progress") {
                Announcer.shared.announce(automatic.spokenProgress, tone: .info)
            }
            .keyboardShortcut("p", modifiers: .command)
            .accessibilityHint("Says how far along it is. Command P.")
        case .finished(let url):
            Text("Ready, and chosen as the installer: \(url.lastPathComponent)")
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Error: \(message)")
        }
    }

    @ViewBuilder
    private var automaticButtons: some View {
        switch automatic.phase {
        case .idle, .failed:
            Button("Use Microsoft's Page Instead") { usingBrowser = true }
                .accessibilityHint("Downloads in your browser from Microsoft's web page, with AVM watching")
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Download Windows 11") { automatic.start() }
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityHint("Gets Windows from Microsoft, checks it, makes the installer and chooses it. Command Return.")
        case .finding, .downloading, .verifying, .building:
            Button("Cancel Download") { automatic.cancel() }
                .accessibilityHint("Stops. Nothing is kept.")
            Button("Keep Going in Background") {
                Announcer.shared.announce("AVM keeps going, says how far along it is every 10 percent, and chooses Windows as the installer when it's ready.", tone: .info)
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityHint("Closes this window. The download goes on, and the installer is chosen when it's ready. Escape.")
        case .finished:
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
    }

    // MARK: Microsoft's page, in the browser

    private var browserBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Download Windows 11 for ARM")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Text("The download happens on Microsoft's own page, in your browser. AVM opens the page, tells you how the download is going every gigabyte, checks the file when it's done, and picks it for you. It's about 8 gigabytes, and usually takes 30 to 90 minutes.")
                .foregroundStyle(.secondary)

            HStack {
                Text("Watching: \(assistant.folder.lastPathComponent)")
                    .accessibilityLabel("AVM watches the folder \(assistant.folder.lastPathComponent) for the download")
                Button("Change…") { chooseFolder() }
                    .accessibilityLabel("Change which folder AVM watches")
                    .accessibilityHint("Choose the folder your browser saves downloads in")
            }

            status

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(28)
        .frame(minWidth: 460)
        .onAppear { assistant.inBackground = false }
        // Closed any other way while it's still going: it goes on in the
        // background rather than stopping unannounced.
        .onDisappear {
            switch assistant.phase {
            case .watching, .downloading, .verifying: assistant.inBackground = true
            default: break
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch assistant.phase {
        case .idle:
            EmptyView()
        case .watching, .downloading, .verifying:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(assistant.spokenProgress)
            }
            .accessibilityElement(children: .combine)
            Button("Speak Progress") {
                Announcer.shared.announce(assistant.spokenProgress, tone: .info)
            }
            .keyboardShortcut("p", modifiers: .command)
            .accessibilityHint("Says how much has downloaded. Command P.")
        case .finished(let url):
            Text("Ready: \(url.lastPathComponent)")
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .accessibilityLabel("Error: \(message)")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch assistant.phase {
        case .idle, .failed:
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Open Microsoft's Download Page") { assistant.start() }
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityHint("Opens the page in your browser and starts watching for the download. Command Return.")
        case .watching, .downloading, .verifying:
            Button("Open the Page Again") { NSWorkspace.shared.open(WindowsISODownloader.pageURL) }
            // Stop Watching used to be the only way out, and it sounded
            // like it cancelled the download (2026-10-27, tester
            // feedback). Closing now keeps watching; stopping says what
            // it did.
            Button("Stop Watching") {
                assistant.stop()
                Announcer.shared.announce("AVM stopped watching the download. Your browser keeps downloading; when it's done, choose the file with Choose Installer Image.", tone: .info)
                dismiss()
            }
            .accessibilityHint("AVM stops telling you about the download. The browser keeps downloading.")
            Button("Keep Watching in Background") {
                assistant.inBackground = true
                Announcer.shared.announce("AVM keeps watching the download and tells you every gigabyte. When it's done, AVM checks it and chooses it as the installer.", tone: .info)
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityHint("Closes this window. AVM goes on telling you how the download is going, and chooses the file when it's ready. Escape.")
        case .finished(let url):
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Use This Installer") {
                onFinished(url)
                dismiss()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityHint("Picks the downloaded file as this virtual machine's installer")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch This Folder"
        panel.message = "Choose the folder your browser saves downloads in."
        panel.directoryURL = assistant.folder
        if panel.runModal() == .OK, let url = panel.url {
            assistant.setFolder(url)
            Announcer.shared.announce("AVM will watch \(url.lastPathComponent) for the download.", tone: .info)
        }
    }
}
