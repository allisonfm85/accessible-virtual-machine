// ReclaimView.swift
// AVM — Accessible Virtual Machine
//
// The "Reclaim Disk Space" sheet (2026-08-15). Cleans up orphaned VM
// directories — the debris the pre-fix delete (issue #5) left behind on
// every tester's machine.
//
// DESIGN OF RECORD (all four points approved 2026-08-15):
//   1. Orphan = UUID-named directory in VMs/ with no matching
//      configuration entry. Non-UUID names are invisible to this feature.
//      (Definition lives in VMStore.findOrphans; this view never decides
//      what is an orphan, it only presents.)
//   2. Sole trigger is the menu item; the scan is fresh at invocation.
//      The no-orphans case never opens this sheet (the menu action
//      announces instead) — but if the last item is trashed while the
//      sheet is open, the sheet shows the honest empty state below.
//   3. Rows are real checkbox elements, DEFAULT UNCHECKED, labeled by
//      size and date ("Leftover folder, about 24 gigabytes, from
//      July 12, 2026") — recognition without UUID torture. The UUID
//      lives in the accessibility HINT for Finder cross-reference.
//      Live selection total. Cancel is the default button.
//   4. NEVER-LIST: nothing outside VMs/ is touched; nothing is ever
//      auto-selected (no select-all button — that is auto-selection one
//      keystroke removed, and the misfire commits everything); never
//      runs at launch or on a timer; Trash only, never permanent.
//
// ANNOUNCEMENTS:
//   - Move to Trash with nothing selected: .info (guidance, not alarm —
//     the SetupView precedent for incomplete form submissions).
//   - Success: one summary with count, size, and the Trash-recovery
//     note (.success, Glass).
//   - Partial failure: which count succeeded, and that the rest are
//     untouched (.failure, Basso). The list refreshes to what remains.

import SwiftUI

struct ReclaimView: View {

    @EnvironmentObject var vmStore: VMStore
    @Environment(\.dismiss) private var dismiss

    /// The orphans currently shown. Loaded fresh when the sheet appears
    /// (the invoking menu action also scans, to decide whether to open
    /// the sheet at all — that double scan is cheap and keeps this view
    /// self-sufficient).
    @State private var orphans: [OrphanedVMDirectory] = []

    /// UUIDs of the checked rows. Always starts empty (never-list: no
    /// auto-selection).
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("Reclaim Disk Space")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)

            if orphans.isEmpty {
                // Honest empty state — reachable only if the last orphan
                // was trashed while the sheet was open (the menu action
                // handles the nothing-found case without opening it).
                Text("No leftover files found. Nothing to reclaim.")
                    .font(.body)
            } else {
                Text("These folders were left behind by earlier versions of AVM and do not belong to any virtual machine in your list. Check the ones you want to move to the Trash.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(orphans) { orphan in
                    Toggle(isOn: binding(for: orphan)) {
                        Text(rowLabel(for: orphan))
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityHint("Folder name \(orphan.uuidString). Check to include it when moving to the Trash.")
                }

                Text(selectionSummary)
                    .font(.body)
                    .accessibilityLabel(selectionSummary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if !orphans.isEmpty {
                    Button("Move to Trash") {
                        moveSelectedToTrash()
                    }
                    // Always enabled (decision of record): a grayed
                    // button is a silent riddle. Pressing with nothing
                    // selected answers honestly instead (see
                    // moveSelectedToTrash).
                }
            }
        }
        .padding(24)
        .frame(minWidth: 460)
        .onAppear {
            orphans = vmStore.findOrphans()
        }
    }

    // MARK: - Row helpers

    private func binding(for orphan: OrphanedVMDirectory) -> Binding<Bool> {
        Binding(
            get: { selected.contains(orphan.uuidString) },
            set: { isOn in
                if isOn {
                    selected.insert(orphan.uuidString)
                } else {
                    selected.remove(orphan.uuidString)
                }
            }
        )
    }

    /// "Leftover folder, about 24 gigabytes, from July 12, 2026" — size
    /// for weight, date for recognition, no UUID in the reading path.
    private func rowLabel(for orphan: OrphanedVMDirectory) -> String {
        var label = "Leftover folder, \(spokenSize(orphan.sizeBytes))"
        if let date = orphan.modificationDate {
            label += ", from \(Self.dateFormatter.string(from: date))"
        }
        return label
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private var selectionSummary: String {
        if selected.isEmpty {
            return "Nothing selected"
        }
        let chosen = orphans.filter { selected.contains($0.uuidString) }
        let totalBytes = chosen.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let folderWord = chosen.count == 1 ? "folder" : "folders"
        return "\(chosen.count) \(folderWord) selected, \(spokenSize(totalBytes))"
    }

    // MARK: - Actions

    private func moveSelectedToTrash() {
        guard !selected.isEmpty else {
            Announcer.shared.announce(
                "Nothing is selected. Check the folders you want to move to the Trash.",
                tone: .info
            )
            return
        }

        let chosen = orphans.filter { selected.contains($0.uuidString) }
        var trashedCount = 0
        var trashedBytes: UInt64 = 0
        var firstError: Error? = nil

        for orphan in chosen {
            do {
                try vmStore.trashOrphan(orphan)
                trashedCount += 1
                trashedBytes += orphan.sizeBytes
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // Refresh to ground truth — never trust our own bookkeeping over
        // a fresh scan.
        orphans = vmStore.findOrphans()
        selected.removeAll()

        if let error = firstError {
            let failedCount = chosen.count - trashedCount
            let failedWord = failedCount == 1 ? "folder" : "folders"
            let trashedWord = trashedCount == 1 ? "folder" : "folders"
            Announcer.shared.announce(
                trashedCount == 0
                    ? "Moving to the Trash failed. Nothing was moved. \(error.localizedDescription)"
                    : "\(trashedCount) \(trashedWord) moved to the Trash, but \(failedCount) \(failedWord) could not be moved and are untouched. \(error.localizedDescription)",
                tone: .failure
            )
            return
        }

        let folderWord = trashedCount == 1 ? "folder" : "folders"
        Announcer.shared.announce(
            "\(trashedCount) \(folderWord), \(spokenSize(trashedBytes)), moved to the Trash. You can recover them from the Trash until it is emptied.",
            tone: .success
        )

        if orphans.isEmpty {
            dismiss()
        }
    }

    // MARK: - Spoken size

    /// Duplicated from ContentView (private there) — promoting it to a
    /// shared home is banked cleanup, not tonight's fourth file.
    private func spokenSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            return "about \(Int(gb.rounded())) gigabytes"
        }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 {
            return "about \(Int(mb.rounded())) megabytes"
        }
        return "less than one megabyte"
    }
}
