import Foundation

struct Entitlement: Codable, Equatable {
    static let trialDuration: TimeInterval = 30 * 86_400
    var firstOpen: Date
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date {
        let local = proStartedAt ?? firstOpen
        return min(local, trialClaimedAt ?? local)
    }
    var trialEnd: Date { trialStart.addingTimeInterval(Self.trialDuration) }

    mutating func startPaidPeriod(at now: Date) {
        if proStartedAt == nil { proStartedAt = now }
    }

    mutating func recognizeTrial(at date: Date) {
        trialClaimedAt = min(trialClaimedAt ?? date, date)
    }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (now >= trialStart.addingTimeInterval(-600) && now < trialEnd)
    }
}
