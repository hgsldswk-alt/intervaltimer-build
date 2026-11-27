import AVFoundation
import UIKit
import UserNotifications

@MainActor
final class WorkoutCues {
    private let voice = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    func stop() {
        player?.stop()
        voice.stopSpeaking(at: .immediate)
    }

    func play(_ title: String, spoken: Bool, sound: Bool, haptic: Bool) {
        guard !Launch.testing, UIApplication.shared.applicationState == .active else { return }
        if haptic { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        guard sound || spoken else { return }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.ambient, mode: .default)
            try audio.setActive(true)
        } catch { return }
        stop()
        if spoken {
            let preferred = Bundle.main.preferredLocalizations.first ?? "en"
            let code = preferred.hasPrefix("zh-Hant") ? "zh-TW" : preferred.hasPrefix("zh") ? "zh-CN" : "en-US"
            if let speaker = AVSpeechSynthesisVoice(language: code) {
                let utterance = AVSpeechUtterance(string: title)
                utterance.voice = speaker
                voice.speak(utterance)
                return
            }
        }
        if let url = Bundle.main.url(forResource: "interval-cue", withExtension: "wav") {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.play()
        }
    }
}

final class NoticeDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let prefix = "interval-workout."
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix(Self.prefix) ? [] : [.banner, .sound]
    }
}

enum NoticePermission: Equatable {
    case unknown, allowed, denied
}

@MainActor
final class WorkoutNotices {
    private struct Schedule {
        let session: SessionSnapshot
        let sound: Bool
        var anchor: TimeInterval { session.checkpoint.continuous - session.elapsed }

        func matches(_ other: Schedule) -> Bool {
            session.id == other.session.id && sound == other.sound && abs(anchor - other.anchor) < 0.01
        }
    }

    private let center = UNUserNotificationCenter.current()
    private var task: Task<Void, Never>?
    private var revision = 0
    private var scheduled: Schedule?
    private var hasReconciled = false

    func authorization() async -> NoticePermission {
        if Launch.testing { return .unknown }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .unknown
        }
    }

    func request() async -> NoticePermission {
        guard !Launch.testing else { return .unknown }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    func replace(for snapshot: SessionSnapshot?, enabled: Bool, sound: Bool) {
        guard !Launch.testing else { return }
        let next = snapshot.flatMap { enabled && $0.running ? Schedule(session: $0, sound: sound) : nil }
        if hasReconciled {
            if let scheduled, let next, scheduled.matches(next) { return }
            if scheduled == nil && next == nil { return }
        }
        hasReconciled = true
        scheduled = next
        revision += 1
        let current = revision
        let previous = task
        task = Task { [weak self] in
            await previous?.value
            guard let self, self.revision == current else { return }
            let pending = await self.center.pendingNotificationRequests()
            guard self.revision == current else { return }
            let old = pending.map(\.identifier).filter { $0.hasPrefix(NoticeDelegate.prefix) }
            if !old.isEmpty { self.center.removePendingNotificationRequests(withIdentifiers: old) }
            guard let next,
                  await self.authorization() == .allowed, self.revision == current else { return }
            let snapshot = next.session
            let timeline = Timeline(snapshot.plan.parameters)
            for stage in timeline.upcomingBoundaries(at: snapshot.progress(at: .now())) {
                guard self.revision == current else { return }
                let remaining = Double(stage.end) - snapshot.progress(at: .now())
                guard remaining > 0 else { continue }
                let content = UNMutableNotificationContent()
                content.title = snapshot.plan.name
                if stage.index + 1 < timeline.stages.count {
                    let next = timeline.stages[stage.index + 1]
                    content.body = L.f("notice.next", next.kind.title, Int64(next.duration))
                } else {
                    content.body = L.t("result.completed")
                }
                if next.sound { content.sound = .default }
                let id = "\(NoticeDelegate.prefix)\(snapshot.id.uuidString).\(current).\(stage.index)"
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, remaining), repeats: false)
                try? await self.center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                if self.revision != current {
                    self.center.removePendingNotificationRequests(withIdentifiers: [id])
                    return
                }
            }
        }
    }
}
