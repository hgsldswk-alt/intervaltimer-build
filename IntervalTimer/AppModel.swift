import SwiftUI
import UIKit

struct Preferences: Codable {
    var sound = true
    var haptics = true
    var voice = false
    var lockNotices = false
}

@MainActor
final class AppModel: ObservableObject {
    enum LoadState: Equatable { case loading, ready, failed }

    let purchases = Purchases()
    private let store = WorkoutStore()
    private let notices = WorkoutNotices()
    private lazy var cues = WorkoutCues()
    @Published private(set) var data = WorkoutData()
    @Published private(set) var loadState = LoadState.loading
    @Published private(set) var clock = ClockReading.now()
    @Published private(set) var selectedID = Plan.presets[0].id
    @Published private(set) var preferences = Preferences()
    @Published private(set) var noticePermission = NoticePermission.unknown
    @Published private(set) var busy = false
    @Published private(set) var ratingPending = false
    @Published private(set) var copied: String?
    @Published private(set) var finishBlocked = false
    @Published var result: WorkoutRecord?
    @Published var message: String?
    private var scene = ScenePhase.inactive
    private var checkpointPending = false
    private var lastStageIndex: Int?
    private var fixtureClock: ClockReading?
    private var ratingVersion = ""
    private var alreadyRequestedRating = false
    private var copyTask: Task<Void, Never>?
    private let preferencesKey = "interval.preferences"
    private let ratingKey = "interval.ratingVersion"

    var selected: Plan { data.allPlans.first { $0.id == selectedID } ?? Plan.presets[0] }
    var alternatives: [Plan] { data.allPlans.filter { $0.id != selectedID } }
    var snapshot: SessionSnapshot? { data.session }
    var elapsed: TimeInterval { snapshot?.progress(at: clock) ?? 0 }
    var orderedRecords: [WorkoutRecord] { data.records.sorted { $0.startedAt > $1.startedAt } }

    func initialize() async {
        guard loadState != .ready, !busy else { return }
        busy = true
        loadState = .loading
        defer { busy = false }
        if !Launch.testing {
            let key = preferencesKey
            let loaded = await Task.detached(priority: .utility) {
                UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
            }.value
            preferences = loaded ?? Preferences()
        }
        ratingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        alreadyRequestedRating = !Launch.testing && UserDefaults.standard.string(forKey: ratingKey) == ratingVersion
        async let startPurchases: Void = purchases.initialize()
        noticePermission = await notices.authorization()
        do {
            var loaded = try await store.load(seed: fixtures())
            clock = readClock()
            if var session = loaded.session {
                let finished = loaded.records.contains { $0.id == session.id }
                session.restore(at: clock)
                loaded.session = session
                if finished || session.progress(at: clock) >= Double(session.plan.parameters.total) {
                    result = loaded.finish(session, at: clock, completed: true)
                }
                try await store.save(loaded)
            }
            data = loaded
            selectedID = data.allPlans.first { $0.id == data.lastPlanID }?.id ?? Plan.presets[0].id
            if Launch.flag("-result-shot") { result = data.records.first }
            ratingPending = data.completedCount >= 5 && !alreadyRequestedRating
            loadState = .ready
            if let snapshot, scene == .active, !Launch.flag("-stage-shot") {
                setIdleTimer(snapshot.running)
            }
            synchronizeStage()
            scheduleNotices()
        } catch {
            loadState = .failed
        }
        await startPurchases
    }

    func didChangeScene(_ phase: ScenePhase) async {
        scene = phase
        guard loadState == .ready else { return }
        if phase == .active {
            clock = readClock()
            synchronizeStage()
            setIdleTimer(snapshot?.running == true)
            if let snapshot, elapsed >= Double(snapshot.plan.parameters.total) {
                await finish(completed: true, cue: false)
            }
            let newPermission = await notices.authorization()
            guard scene == .active else { return }
            noticePermission = newPermission
            if !Launch.isFree, !Launch.testing { Task { await purchases.refresh() } }
        } else {
            setIdleTimer(false)
            cues.stop()
            checkpointPending = checkpointPending || snapshot?.running == true
            scheduleNotices()
            await flushCheckpoint()
            return
        }
        scheduleNotices()
    }

    func tick() async {
        guard scene == .active, !busy, !finishBlocked, let snapshot, snapshot.running else { return }
        clock = readClock()
        let timeline = Timeline(snapshot.plan.parameters)
        guard elapsed < Double(timeline.total) else {
            await finish(completed: true, cue: lastStageIndex != nil)
            return
        }
        if let stage = timeline.signal(after: lastStageIndex, at: elapsed) {
            signal(stage.kind.title, session: snapshot)
        }
        lastStageIndex = timeline.stage(at: elapsed)?.index
    }

    func select(_ plan: Plan) { selectedID = plan.id }

    @discardableResult
    func start(_ plan: Plan) async -> Bool {
        guard snapshot == nil, plan.parameters.isValid else { return false }
        var next = data
        let now = readClock()
        let session = SessionSnapshot(plan: plan, at: now, voice: preferences.voice && purchases.hasPro)
        next.session = session
        next.lastPlanID = plan.id
        guard await commit(next) else { return false }
        started(session)
        return true
    }

    func togglePause() async {
        guard var snapshot else { return }
        let now = readClock()
        if snapshot.progress(at: now) >= Double(snapshot.plan.parameters.total) {
            await finish(completed: true, cue: scene == .active)
            return
        }
        snapshot.mark(at: now, running: !snapshot.running)
        var next = data
        next.session = snapshot
        guard await commit(next) else { return }
        clock = readClock()
        setIdleTimer(snapshot.running && scene == .active)
        synchronizeStage()
        scheduleNotices()
        if !snapshot.running { cues.stop() }
    }

    func finish(completed: Bool, cue: Bool = false) async {
        guard !busy, let snapshot else { return }
        let now = readClock()
        let naturallyCompleted = completed || snapshot.progress(at: now) >= Double(snapshot.plan.parameters.total)
        var next = data
        let record = next.finish(snapshot, at: now, completed: naturallyCompleted)
        guard await commit(next) else {
            if naturallyCompleted {
                finishBlocked = true
                setIdleTimer(false)
                cues.stop()
                notices.replace(for: nil, enabled: false, sound: false)
            }
            return
        }
        finishBlocked = false
        result = record
        if record.completed, data.completedCount >= 5, !alreadyRequestedRating { ratingPending = true }
        setIdleTimer(false)
        scheduleNotices()
        if cue, scene == .active, record.completed { signal(L.t("result.completed"), session: snapshot) }
        else { cues.stop() }
    }

    func save(_ parameters: PlanParameters, editing source: Plan?) async -> Bool {
        guard parameters.isValid else { return false }
        guard purchases.hasPro else {
            message = "purchase.expired"
            return false
        }
        var next = data
        let plan: Plan
        if let source, let index = next.plans.firstIndex(where: { $0.id == source.id }) {
            plan = Plan(id: source.id, parameters: parameters)
            next.plans[index] = plan
        } else {
            plan = next.importing(parameters)
        }
        guard await commit(next) else { return false }
        selectedID = plan.id
        return true
    }

    func importPlan(_ parameters: PlanParameters, start shouldStart: Bool) async -> Bool {
        guard parameters.isValid, !shouldStart || snapshot == nil else { return false }
        var next = data
        let plan = next.importing(parameters)
        if shouldStart {
            next.session = SessionSnapshot(plan: plan, at: readClock(), voice: preferences.voice && purchases.hasPro)
            next.lastPlanID = plan.id
        }
        guard await commit(next) else { return false }
        selectedID = plan.id
        if shouldStart, let session = next.session { started(session) }
        return true
    }

    func updatePreference(_ keyPath: WritableKeyPath<Preferences, Bool>, to enabled: Bool) {
        preferences[keyPath: keyPath] = enabled
        if !Launch.testing, let bytes = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(bytes, forKey: preferencesKey)
        }
        if keyPath == \.lockNotices || keyPath == \.sound { scheduleNotices() }
    }

    func setLockNotices(_ enabled: Bool) async {
        if enabled {
            noticePermission = await notices.request()
            updatePreference(\.lockNotices, to: true)
        } else {
            updatePreference(\.lockNotices, to: false)
        }
    }

    func copy(_ value: String, notice: String) {
        UIPasteboard.general.string = value
        copied = notice
        copyTask?.cancel()
        copyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.copied = nil }
        }
    }

    func markRatingRequested() {
        alreadyRequestedRating = true
        ratingPending = false
        if !Launch.testing { UserDefaults.standard.set(ratingVersion, forKey: ratingKey) }
    }

    private func commit(_ next: WorkoutData, quiet: Bool = false) async -> Bool {
        guard !busy, loadState == .ready else { return false }
        busy = true
        defer {
            busy = false
            if checkpointPending { Task { await flushCheckpoint() } }
        }
        do {
            try await store.save(next)
            data = next
            return true
        } catch {
            if !quiet && message == nil { message = "error.save" }
            return false
        }
    }

    func dismissError() { message = nil }

    func retrySave() async {
        message = nil
        guard let snapshot,
              snapshot.progress(at: readClock()) >= Double(snapshot.plan.parameters.total) else { return }
        await finish(completed: true)
    }

    private func flushCheckpoint() async {
        guard checkpointPending, !busy else { return }
        checkpointPending = false
        guard var snapshot, snapshot.running else { return }
        snapshot.mark(at: readClock(), running: true)
        var next = data
        next.session = snapshot
        _ = await commit(next, quiet: true)
    }

    private func readClock() -> ClockReading { fixtureClock ?? .now() }

    private func started(_ session: SessionSnapshot) {
        selectedID = session.plan.id
        result = nil
        clock = readClock()
        synchronizeStage()
        setIdleTimer(scene == .active)
        scheduleNotices()
        if scene == .active, let stage = Timeline(session.plan.parameters).stage(at: elapsed) {
            signal(stage.kind.title, session: session)
        }
    }

    private func setIdleTimer(_ enabled: Bool) { UIApplication.shared.isIdleTimerDisabled = enabled }
    private func synchronizeStage() {
        lastStageIndex = snapshot.flatMap { Timeline($0.plan.parameters).stage(at: elapsed)?.index }
    }
    private func scheduleNotices() {
        notices.replace(for: snapshot,
                        enabled: preferences.lockNotices && noticePermission == .allowed && !finishBlocked,
                        sound: preferences.sound)
    }
    private func signal(_ title: String, session: SessionSnapshot) {
        cues.play(title, spoken: session.voice, sound: preferences.sound || (preferences.voice && !session.voice),
                  haptic: preferences.haptics)
    }

    private func fixtures() -> WorkoutData {
        guard Launch.testing else { return WorkoutData() }
        let plan = Plan.presets[0]
        let now = ClockReading.now()
        var value = WorkoutData()
        if Launch.flag("-home-shot") { value.lastPlanID = plan.id }
        if Launch.flag("-stage-shot") {
            fixtureClock = now
            var session = SessionSnapshot(plan: plan, at: now, voice: false)
            session.elapsed = 144
            value.session = session
            value.lastPlanID = plan.id
        }
        let count = Launch.flag("-milestone") ? 9 : Launch.flag("-history-shot") ? 3 : Launch.flag("-result-shot") ? 1 : 0
        for day in 0..<count {
            let age = Double(count - day) * 86_400
            let start = ClockReading(wall: now.wall.addingTimeInterval(-age), continuous: now.continuous - age)
            let session = SessionSnapshot(plan: plan, at: start, voice: false)
            _ = value.finish(session, at: ClockReading(wall: start.wall.addingTimeInterval(470),
                                                        continuous: start.continuous + 470), completed: true)
        }
        return value
    }
}
