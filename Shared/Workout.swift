import Darwin
import Foundation

enum StageKind: String, Codable {
    case prepare, work, rest, cooldown
    var title: String { L.t("phase." + rawValue) }
}

struct Stage: Equatable {
    let index: Int
    let kind: StageKind
    let round: Int
    let start: Int
    let end: Int
    var duration: Int { end - start }
}

struct Timeline {
    let stages: [Stage]
    let total: Int

    init(_ plan: PlanParameters) {
        var stages: [Stage] = []
        var offset = 0
        func append(_ kind: StageKind, _ seconds: Int, round: Int) {
            guard seconds > 0 else { return }
            stages.append(Stage(index: stages.count, kind: kind, round: round, start: offset, end: offset + seconds))
            offset += seconds
        }
        if plan.isValid {
            append(.prepare, plan.prepare, round: 1)
            for round in 1...plan.rounds {
                append(.work, plan.work, round: round)
                if round < plan.rounds { append(.rest, plan.rest, round: round) }
            }
            append(.cooldown, plan.cooldown, round: plan.rounds)
        }
        self.stages = stages
        total = offset
    }

    func stage(at elapsed: TimeInterval) -> Stage? { stages.first { elapsed < Double($0.end) } }
    func remaining(in stage: Stage, at elapsed: TimeInterval) -> Int {
        max(0, Int(ceil(Double(stage.end) - elapsed)))
    }
    func rounds(at elapsed: TimeInterval) -> Int {
        stages.filter { $0.kind == .work && elapsed >= Double($0.end) }.count
    }
    func workSeconds(at elapsed: TimeInterval) -> Int {
        let work = stages.filter { $0.kind == .work }
            .reduce(0.0) { $0 + min(Double($1.duration), max(0, elapsed - Double($1.start))) }
        return Int(work.rounded(.down))
    }

    func signal(after previous: Int?, at elapsed: TimeInterval) -> Stage? {
        guard let stage = stage(at: elapsed), let previous, previous != stage.index else { return nil }
        return stage
    }

    func upcomingBoundaries(at elapsed: TimeInterval) -> ArraySlice<Stage> {
        stages.drop(while: { Double($0.end) <= elapsed })
    }
}

struct ClockReading: Codable, Equatable {
    var wall: Date
    var continuous: TimeInterval

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func now() -> ClockReading {
        ClockReading(wall: Date(), continuous: Double(mach_continuous_time()) * secondsPerTick)
    }

    func trustedGap(since old: ClockReading) -> TimeInterval? {
        let monotonic = continuous - old.continuous
        let civil = wall.timeIntervalSince(old.wall)
        guard monotonic.isFinite, civil.isFinite, monotonic >= 0, civil >= 0,
              abs(monotonic - civil) <= 2 else { return nil }
        return monotonic
    }
}

struct SessionSnapshot: Codable, Equatable, Identifiable {
    let id: UUID
    let plan: Plan
    let startedAt: Date
    let localDate: String
    let timeZoneID: String
    let voice: Bool
    var running: Bool
    var elapsed: TimeInterval
    var checkpoint: ClockReading
    var needsResume = false

    init(plan: Plan, at clock: ClockReading, voice: Bool, timeZone: TimeZone = .current) {
        id = UUID()
        self.plan = plan
        startedAt = clock.wall
        timeZoneID = timeZone.identifier
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        localDate = formatter.string(from: clock.wall)
        self.voice = voice
        running = true
        elapsed = 0
        checkpoint = clock
    }

    func progress(at clock: ClockReading) -> TimeInterval {
        elapsed + (running ? max(0, clock.continuous - checkpoint.continuous) : 0)
    }

    mutating func mark(at clock: ClockReading, running: Bool) {
        elapsed = progress(at: clock)
        checkpoint = clock
        self.running = running
        needsResume = false
    }

    mutating func restore(at clock: ClockReading) {
        if running {
            if let gap = clock.trustedGap(since: checkpoint) {
                elapsed += gap
            } else {
                running = false
                needsResume = true
            }
        }
        checkpoint = clock
    }
}

struct WorkoutRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let plan: Plan
    let startedAt: Date
    let endedAt: Date
    let localDate: String
    let timeZoneID: String
    let rounds: Int
    let workSeconds: Int
    let totalSeconds: Int
    let completed: Bool
    let milestone: Int?

    init(session: SessionSnapshot, elapsed: TimeInterval, endedAt: Date, completed: Bool, milestone: Int?) {
        let timeline = Timeline(session.plan.parameters)
        id = session.id
        plan = session.plan
        startedAt = session.startedAt
        self.endedAt = endedAt
        localDate = session.localDate
        timeZoneID = session.timeZoneID
        let progress = completed ? Double(timeline.total) : min(Double(timeline.total), max(0, elapsed))
        rounds = timeline.rounds(at: progress)
        workSeconds = timeline.workSeconds(at: progress)
        totalSeconds = Int(progress.rounded(.down))
        self.completed = completed
        self.milestone = milestone
    }
}
