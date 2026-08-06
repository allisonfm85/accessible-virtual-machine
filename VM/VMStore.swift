// VMStore.swift
// AVM — Accessible Virtual Machine

import Foundation
import Combine

final class VMStore: ObservableObject {

    // MARK: - Published State

    @Published private(set) var configurations: [VMConfiguration] = []

    // MARK: - Private Properties

    private let fileManager = FileManager.default

    private var storeURL: URL {
        get throws {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let avmDirectory = appSupport.appendingPathComponent("AVM")
            try fileManager.createDirectory(
                at: avmDirectory,
                withIntermediateDirectories: true
            )
            return avmDirectory.appendingPathComponent("configurations.json")
        }
    }

    // MARK: - Init

    init() {
        configurations = loadAll()
    }

    // MARK: - Load

    // STAGE C (2026-08-03): the two failure lines in this file were promoted
    // from print() — which goes to stdout, i.e. NOWHERE for a launched app —
    // to the file log. These are the persistence layer failing: a tester
    // whose VM list comes up empty, or whose new VM vanishes after a
    // relaunch, is diagnosed by exactly these lines, and until this change
    // they were invisible in every log AVM has.
    //
    // BANKED QUESTION (not changed here — behavior change, needs its own
    // decision and wording approval): a SAVE failure is silent data loss —
    // the in-memory list looks right and the truth only surfaces at next
    // launch. Under "silence is never neutral" it is a candidate for a
    // spoken .failure announcement, not just a log line. Queued for the
    // announcements work.

    private func loadAll() -> [VMConfiguration] {
        do {
            let url = try storeURL
            guard fileManager.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([VMConfiguration].self, from: data)
        } catch {
            AVMLog.write("AVM: VMStore — FAILED to load configurations: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Save All

    private func saveAll() {
        do {
            let url = try storeURL
            let data = try JSONEncoder().encode(configurations)
            try data.write(to: url, options: .atomic)
        } catch {
            AVMLog.write("AVM: VMStore — FAILED to save configurations: \(error.localizedDescription)")
        }
    }

    // MARK: - Add or Update

    func save(_ configuration: VMConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }
        saveAll()
    }

    // MARK: - Delete

    func delete(_ configuration: VMConfiguration) {
        configurations.removeAll { $0.id == configuration.id }
        saveAll()
    }
}
