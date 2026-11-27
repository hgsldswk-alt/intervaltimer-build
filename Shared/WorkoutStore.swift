import Foundation

struct WorkoutData: Codable, Equatable {
    var schema = 1
    var plans: [Plan] = []
    var records: [WorkoutRecord] = []
    var lastPlanID: UUID?
    var session: SessionSnapshot?

    var allPlans: [Plan] { Plan.presets + plans }
    var completedCount: Int { records.lazy.filter(\.completed).count }

    mutating func importing(_ parameters: PlanParameters) -> Plan {
        if let existing = allPlans.first(where: { $0.portableParameters == parameters || $0.parameters == parameters }) {
            return existing
        }
        let plan = Plan(id: UUID(), parameters: parameters)
        plans.insert(plan, at: 0)
        return plan
    }

    @discardableResult
    mutating func finish(_ snapshot: SessionSnapshot, at clock: ClockReading, completed: Bool) -> WorkoutRecord {
        if let existing = records.first(where: { $0.id == snapshot.id }) {
            if session?.id == snapshot.id { session = nil }
            return existing
        }
        let count = completedCount + 1
        let elapsed = snapshot.progress(at: clock)
        let overflow = completed ? max(0, elapsed - Double(snapshot.plan.parameters.total)) : 0
        let record = WorkoutRecord(session: snapshot, elapsed: elapsed,
                                   endedAt: max(snapshot.startedAt, clock.wall.addingTimeInterval(-overflow)),
                                   completed: completed,
                                   milestone: completed && [10, 25, 50].contains(count) ? count : nil)
        records.insert(record, at: 0)
        if session?.id == snapshot.id { session = nil }
        return record
    }

    var valid: Bool {
        schema == 1 && plans.allSatisfy { $0.parameters.isValid }
            && records.allSatisfy { $0.plan.parameters.isValid }
            && (session.map { $0.plan.parameters.isValid && $0.elapsed.isFinite && $0.elapsed >= 0 } ?? true)
    }
}

actor WorkoutStore {
    enum Failure: Error { case unsupported, notLoaded }
    private let directory: URL?
    private var lastSaved: WorkoutData?

    init(directory: URL? = nil) { self.directory = directory }

    private func file() throws -> URL {
        if let directory { return directory.appendingPathComponent("workouts.json") }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        if Launch.testing {
            let value = ProcessInfo.processInfo.environment["INTERVAL_TEST_STORE"] ?? ""
            let id = UUID(uuidString: value)?.uuidString ?? "Default"
            return root.appendingPathComponent("IntervalTimer-UITesting/\(id)/workouts.json")
        }
        return root.appendingPathComponent("IntervalTimer/workouts.json")
    }

    func load(seed: WorkoutData = WorkoutData()) throws -> WorkoutData {
        if let lastSaved { return lastSaved }
        let file = try file()
        if directory == nil, Launch.flag("-reset") {
            do {
                try FileManager.default.removeItem(at: file)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            }
        }
        do {
            let bytes = try Data(contentsOf: file)
            let value = try JSONDecoder().decode(WorkoutData.self, from: bytes)
            guard value.valid else { throw Failure.unsupported }
            lastSaved = value
            return value
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if seed != WorkoutData() {
                try write(seed, to: file)
            }
            lastSaved = seed
            return seed
        }
    }

    func save(_ value: WorkoutData) throws {
        guard lastSaved != nil else { throw Failure.notLoaded }
        guard value.valid else { throw Failure.unsupported }
        try write(value, to: file())
        lastSaved = value
    }

    private func write(_ value: WorkoutData, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }
}
