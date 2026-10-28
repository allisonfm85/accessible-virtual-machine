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
    /// Called with the downloaded ISO when the user chooses to use it.
    let onFinished: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
