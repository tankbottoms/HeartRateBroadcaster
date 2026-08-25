import Foundation
import Observation

/// Sessions on disk.
///
/// One file per session rather than one growing array, so a single corrupt
/// write costs one ride instead of the history. The list is rebuilt by reading
/// the directory at launch, which means there is no index to fall out of sync
/// with the files it describes.
@Observable
@MainActor
final class WorkoutStore {

    /// What was known at Start. Written before the first sample and removed at
    /// Stop, so its presence at launch means exactly one thing: the app did not
    /// reach Stop.
    struct Journal: Codable, Sendable {
        let id: UUID
        let sport: WorkoutSport
        let start: Date
    }

    private(set) var records: [WorkoutRecord] = []

    private let directory: URL
    private let journalURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Workouts", isDirectory: true)
        journalURL = base.appendingPathComponent("session-journal.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        records = files
            .filter { $0.pathExtension == "json" }
            // A file that will not decode is skipped rather than fatal: one bad
            // ride must not take the history down with it.
            .compactMap { try? decoder.decode(WorkoutRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.start > $1.start }
    }

    func save(_ record: WorkoutRecord) {
        guard let data = try? encoder.encode(record) else { return }
        let url = directory.appendingPathComponent("\(record.id.uuidString).json")
        try? data.write(to: url, options: .atomic)
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        records.sort { $0.start > $1.start }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
        records.removeAll { $0.id == id }
    }

    // MARK: - Crash journal

    func openJournal(id: UUID, sport: WorkoutSport, start: Date) {
        guard let data = try? encoder.encode(Journal(id: id, sport: sport, start: start)) else { return }
        try? data.write(to: journalURL, options: .atomic)
    }

    func closeJournal() {
        try? FileManager.default.removeItem(at: journalURL)
    }

    /// A journal left behind by a session that never reached Stop. The samples
    /// are gone — they lived in memory — but the sport, the start and the fact
    /// that a ride happened are recoverable, which is enough to offer the user
    /// a session rather than silently pretending it never began.
    func abandonedSession() -> Journal? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        return try? decoder.decode(Journal.self, from: data)
    }
}
