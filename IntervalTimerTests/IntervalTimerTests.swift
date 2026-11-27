import Foundation
import XCTest

final class IntervalTimerTests: XCTestCase {
    private let plan = Plan.presets[0]
    private let baseline = ClockReading(wall: Date(timeIntervalSince1970: 1_701_000_000), continuous: 50_000)

    private func at(_ seconds: TimeInterval, wallDelta: TimeInterval? = nil) -> ClockReading {
        ClockReading(wall: baseline.wall.addingTimeInterval(wallDelta ?? seconds),
                     continuous: baseline.continuous + seconds)
    }

    func testPresetTimelinesAndExactBoundary() throws {
        XCTAssertEqual(Plan.presets.map { Timeline($0.parameters).total }, [470, 240, 520])
        let timeline = Timeline(plan.parameters)
        XCTAssertEqual(timeline.stages.last?.kind, .work)
        XCTAssertEqual(timeline.stage(at: 0)?.kind, .prepare)
        XCTAssertEqual(timeline.stage(at: 9.999)?.kind, .prepare)
        XCTAssertEqual(timeline.stage(at: 10)?.kind, .work)
        XCTAssertEqual(timeline.stage(at: 50)?.kind, .rest)
        XCTAssertNil(timeline.stage(at: 470))
        let stage = try XCTUnwrap(timeline.stage(at: 144))
        XCTAssertEqual(stage.round, 3)
        XCTAssertEqual(timeline.remaining(in: stage, at: 144), 26)
        XCTAssertEqual(timeline.remaining(in: stage, at: 169.999), 1)
    }

    func testZeroPhasesAndCooldown() {
        let p = PlanParameters(name: "Test", work: 5, rest: 0, rounds: 2, prepare: 0, cooldown: 8)
        let timeline = Timeline(p)
        XCTAssertEqual(timeline.stages.map(\.kind), [.work, .work, .cooldown])
        XCTAssertEqual(timeline.stages.map(\.end), [5, 10, 18])
        let single = Timeline(PlanParameters(name: "Single", work: 5, rest: 600, rounds: 1, prepare: 0))
        XCTAssertEqual(single.total, 5)
        XCTAssertEqual(single.stages.map(\.kind), [.work])
    }

    func testResumeAcrossMultiplePhasesUsesCurrentCueOnly() {
        let timeline = Timeline(plan.parameters)
        XCTAssertNil(timeline.signal(after: nil, at: 144))
        XCTAssertEqual(timeline.signal(after: 0, at: 144)?.round, 3)
        XCTAssertEqual(timeline.signal(after: 0, at: 144)?.kind, .work)
        XCTAssertNil(timeline.signal(after: timeline.stage(at: 144)?.index, at: 145))
        XCTAssertNil(timeline.signal(after: 0, at: 470))
    }

    func testNoticeScheduleOnlyContainsUpcomingBoundaries() {
        let timeline = Timeline(plan.parameters)
        let atWork = Array(timeline.upcomingBoundaries(at: 144))
        XCTAssertEqual(atWork.first?.end, 170)
        XCTAssertEqual(atWork.last?.end, 470)
        XCTAssertEqual(timeline.upcomingBoundaries(at: 170).first?.kind, .rest)
        XCTAssertTrue(timeline.upcomingBoundaries(at: 470).isEmpty)
    }

    func testPauseResumeAndVoiceEntitlementFreeze() {
        var snapshot = SessionSnapshot(plan: plan, at: baseline, voice: true)
        snapshot.mark(at: at(12.3), running: false)
        XCTAssertEqual(snapshot.progress(at: at(80)), 12.3, accuracy: 0.00001)
        snapshot.mark(at: at(80), running: true)
        XCTAssertEqual(snapshot.progress(at: at(85)), 17.3, accuracy: 0.00001)
        XCTAssertTrue(snapshot.voice)
    }

    func testClockChangesInProcessAndCrossProcessRecovery() {
        let initial = SessionSnapshot(plan: plan, at: baseline, voice: false)
        XCTAssertEqual(initial.progress(at: at(19, wallDelta: -3_600)), 19)
        var restored = initial
        restored.restore(at: at(144))
        XCTAssertTrue(restored.running)
        XCTAssertEqual(restored.progress(at: at(144)), 144)
        restored.restore(at: at(900))
        XCTAssertGreaterThan(restored.elapsed, Double(plan.parameters.total))
        for changed in [at(150, wallDelta: -3_600), at(150, wallDelta: 3_600), at(-4_000, wallDelta: 150)] {
            restored = initial
            restored.restore(at: changed)
            XCTAssertFalse(restored.running)
            XCTAssertTrue(restored.needsResume)
            XCTAssertEqual(restored.elapsed, 0)
        }
    }

    func testCrossingMidnightKeepsStartDateAndOriginalTimeZone() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T14:59:55Z"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let clock = ClockReading(wall: start, continuous: 500)
        let session = SessionSnapshot(plan: plan, at: clock, voice: false, timeZone: tokyo)
        var data = WorkoutData()
        let result = data.finish(session, at: ClockReading(wall: start.addingTimeInterval(470), continuous: 970),
                                 completed: true)
        XCTAssertEqual(result.localDate, "2026-11-19")
        XCTAssertEqual(result.timeZoneID, "Asia/Tokyo")
    }

    func testCompletionIsIdempotentAndUsesPrecisePlannedDuration() {
        let session = SessionSnapshot(plan: plan, at: baseline, voice: false)
        var data = WorkoutData(session: session)
        let result = data.finish(session, at: at(500), completed: true)
        XCTAssertNil(data.session)
        XCTAssertEqual(result.endedAt, at(470).wall)
        XCTAssertEqual(result.rounds, 8)
        XCTAssertEqual(result.workSeconds, 320)
        XCTAssertEqual(result.totalSeconds, 470)
        XCTAssertEqual(data.finish(session, at: at(600), completed: true), result)
        XCTAssertEqual(data.records.count, 1)
    }

    func testEarlyEndDoesNotIncreaseMilestoneCount() {
        var data = WorkoutData()
        for index in 1...10 {
            let session = SessionSnapshot(plan: plan, at: baseline, voice: false)
            let record = data.finish(session, at: at(500), completed: true)
            XCTAssertEqual(record.milestone, index == 10 ? 10 : nil)
        }
        let partial = SessionSnapshot(plan: plan, at: baseline, voice: false)
        let record = data.finish(partial, at: at(83.9), completed: false)
        XCTAssertEqual(record.rounds, 1)
        XCTAssertEqual(record.workSeconds, 53)
        XCTAssertEqual(record.totalSeconds, 83)
        XCTAssertEqual(data.completedCount, 10)
    }

    func testFileAndMultilineCodeRoundTripForThreeLanguages() throws {
        for name in ["爆发循环", "爆發循環", "Boxing ladder", "👩‍👩‍👧‍👦"] {
            let plan = PlanParameters(name: name, work: 45, rest: 0, rounds: 24, prepare: 0, cooldown: 120)
            XCTAssertEqual(try PlanTransfer.decode(PlanTransfer.encode(plan)), plan)
            let code = try PlanTransfer.code(plan)
            XCTAssertEqual(try PlanTransfer.decodeCode("Copy the plan\r\n \(code) \r\n"), plan)
        }
    }

    func testInvalidTransferAndBoundedInputs() throws {
        let p = PlanParameters(name: "Test")
        let code = try PlanTransfer.code(p)
        for text in ["INTERVAL2:abcd", "INTERVAL1:%bad", "INTERVAL1:Y", code + "\n" + code,
                     String(repeating: "A", count: PlanTransfer.maxCodeBytes + 1)] {
            XCTAssertThrowsError(try PlanTransfer.decodeCode(text))
        }
        for bytes in [Data(repeating: 32, count: PlanTransfer.maxBytes + 1), Data("bad".utf8)] {
            XCTAssertThrowsError(try PlanTransfer.decode(bytes))
        }
        XCTAssertThrowsError(try PlanTransfer.encode(PlanParameters(version: 2, name: "Test")))
        XCTAssertFalse(PlanParameters(name: " ", work: 5).isValid)
        XCTAssertFalse(PlanParameters(name: String(repeating: "a", count: 41)).isValid)
        XCTAssertFalse(PlanParameters(name: "Test", work: Int.max).isValid)
        XCTAssertFalse(PlanParameters(name: "Test", work: 600, rest: 600, rounds: 24).isValid)
        XCTAssertTrue(PlanParameters(name: "Test", work: 600, rest: 0, rounds: 12, prepare: 0).isValid)
        XCTAssertEqual(Timeline(PlanParameters(name: "Test", work: 5, rest: 1, rounds: 24,
                                               prepare: 1, cooldown: 1)).stages.count, 49)
    }

    func testImportDeduplicatesOnlyExactMatches() {
        var data = WorkoutData()
        let saved = data.importing(PlanParameters(name: "Class"))
        XCTAssertEqual(data.importing(saved.parameters).id, saved.id)
        XCTAssertNotEqual(data.importing(PlanParameters(name: "Class", work: 20)).id, saved.id)
        XCTAssertEqual(data.plans.count, 2)
        XCTAssertEqual(data.importing(plan.portableParameters).id, plan.id)
    }

    func testPaidLaunchFreePeriodAndTrialReceiptConverge() {
        let origin = baseline.wall
        let firstPaid = origin.addingTimeInterval(80 * 86_400)
        var value = Entitlement(firstOpen: origin)
        XCTAssertTrue(value.hasPro(at: firstPaid, free: true))
        XCTAssertFalse(value.hasPro(at: firstPaid, free: false))
        value.startPaidPeriod(at: firstPaid)
        XCTAssertTrue(value.hasPro(at: firstPaid, free: false))
        XCTAssertTrue(value.hasPro(at: firstPaid.addingTimeInterval(Entitlement.trialDuration - 0.001), free: false))
        XCTAssertFalse(value.hasPro(at: firstPaid.addingTimeInterval(Entitlement.trialDuration), free: false))
        value.recognizeTrial(at: firstPaid.addingTimeInterval(86_400))
        XCTAssertEqual(value.trialStart, firstPaid)
        value.recognizeTrial(at: origin)
        XCTAssertEqual(value.trialStart, origin)
    }

    func testOfflineCacheRestoredPurchaseAndRevocation() throws {
        let first = baseline.wall
        let expired = first.addingTimeInterval(31 * 86_400)
        var value = Entitlement(firstOpen: first, purchasedPro: true)
        let offline = try JSONDecoder().decode(Entitlement.self, from: JSONEncoder().encode(value))
        XCTAssertTrue(offline.hasPro(at: expired, free: false))
        value.purchasedPro = false
        XCTAssertFalse(value.hasPro(at: expired, free: false))
        XCTAssertTrue(plan.parameters.isValid)
        XCTAssertFalse(try PlanTransfer.encode(plan.portableParameters).isEmpty)
    }

    func testFileCorruptionIsPreservedAndBlocksWrites() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workouts.json")
        let contents = Data("not a valid database".utf8)
        try contents.write(to: file)
        let store = WorkoutStore(directory: directory)
        do { _ = try await store.load(); XCTFail("Corrupt file should surface an error") } catch {}
        do { try await store.save(WorkoutData()); XCTFail("Blind save should fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    func testStoreRoundTripAndRejectedWriteLeaveSnapshotIntact() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(directory: directory)
        var data = try await store.load()
        data.session = SessionSnapshot(plan: plan, at: baseline, voice: true)
        try await store.save(data)
        var bad = data
        bad.plans = [Plan(id: UUID(), parameters: PlanParameters(name: "Invalid", work: Int.max))]
        do { try await store.save(bad); XCTFail("Invalid state should be rejected") } catch {}
        let fresh = WorkoutStore(directory: directory)
        let loaded = try await fresh.load()
        XCTAssertEqual(loaded, data)
    }

    func testDiskWriteFailureKeepsLastCommittedSnapshot() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("live", isDirectory: true)
        let backup = root.appendingPathComponent("previous", isDirectory: true)
        let store = WorkoutStore(directory: folder)
        var first = try await store.load()
        first.session = SessionSnapshot(plan: plan, at: baseline, voice: false)
        try await store.save(first)

        try FileManager.default.moveItem(at: folder, to: backup)
        try Data("blocks the directory".utf8).write(to: folder)
        var second = first
        second.session?.mark(at: at(12), running: false)
        do { try await store.save(second); XCTFail("Save should report an I/O failure") } catch {}
        let cached = try await store.load()
        let saved = try JSONDecoder().decode(WorkoutData.self,
                                            from: Data(contentsOf: backup.appendingPathComponent("workouts.json")))
        XCTAssertEqual(cached, first)
        XCTAssertEqual(saved, first)
    }

    private func sandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
