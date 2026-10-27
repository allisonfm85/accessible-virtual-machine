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

    /// Called with the downloaded ISO when the user chooses to use it.
    let onFinished: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var assistant = WindowsISODownloader()

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
        .onDisappear { assistant.stop() }
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
            Button("Stop Watching") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityHint("Closes this window. The browser keeps downloading; choose the file with Choose Installer Image when it's done.")
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
