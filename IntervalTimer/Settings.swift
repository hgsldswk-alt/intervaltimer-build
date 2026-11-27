import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @ObservedObject var purchases: Purchases
    let paywall: () -> Void
    let privacy: () -> Void
    let export: () -> Void
    let recommend: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                PageHeading(title: L.t("tab.settings"))
                VStack(spacing: 0) {
                    preference("settings.sound", \.sound)
                    preference("settings.voice", \.voice, displayed: model.preferences.voice && purchases.hasPro) {
                        if purchases.hasPro { model.updatePreference(\.voice, to: !model.preferences.voice) }
                        else { paywall() }
                    }
                    preference("settings.haptics", \.haptics)
                    preference("settings.lockNotices", \.lockNotices, displayed: model.preferences.lockNotices
                               && model.noticePermission == .allowed) {
                        Task { await model.setLockNotices(!(model.preferences.lockNotices && model.noticePermission == .allowed)) }
                    }
                    if model.noticePermission == .denied {
                        HStack(spacing: 8) {
                            Text(L.t("settings.noticeOff")).font(.footnote).foregroundStyle(Palette.muted)
                            Spacer()
                            QuietButton(title: L.t("settings.openSystem"), id: "settings.openSystem", accent: true) {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                    }
                }
                VStack(spacing: 0) {
                    row("settings.export", action: export)
                    row("settings.recommend", action: recommend)
                    row("settings.privacy", action: privacy)
                }
                if !Launch.isFree {
                    VStack(spacing: 0) {
                        row("settings.pro", action: paywall)
                        row("settings.restore") { Task { await purchases.restore() } }
                            .disabled(purchases.busy)
                    }
                }
            }.pageInsets().padding(.bottom, 15)
        }
        .modifier(PurchaseNotice(purchases: purchases))
    }

    private func preference(_ key: String, _ path: WritableKeyPath<Preferences, Bool>, displayed: Bool? = nil,
                            action: (() -> Void)? = nil) -> some View {
        let on = displayed ?? model.preferences[keyPath: path]
        return VStack(spacing: 0) {
            Rule()
            Button {
                if let action { action() }
                else { model.updatePreference(path, to: !on) }
            } label: {
                HStack {
                    Text(L.t(key)).font(.body)
                    Spacer()
                    Capsule().fill(on ? Palette.accent : Palette.line)
                        .frame(width: 42, height: 24)
                        .overlay(alignment: on ? .trailing : .leading) {
                            Circle().fill(on ? Palette.accentInk : Palette.text)
                                .frame(width: 17, height: 17).padding(.horizontal, 4)
                        }
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityIdentifier(key)
            .accessibilityValue(Text(L.t(on ? "common.on" : "common.off")))
        }
    }

    private func row(_ key: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Rule()
            Button(action: action) {
                HStack {
                    Text(L.t(key)).font(.body)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityIdentifier(key)
        }
    }
}

struct PaywallView: View {
    @ObservedObject var purchases: Purchases
    let close: () -> Void

    var body: some View {
        SheetFrame(title: L.t("purchase.title"), id: "paywall.title", close: close) {
            VStack(alignment: .leading, spacing: 15) {
                Text(L.t("purchase.pitch")).font(.title2.bold())
                Text(L.t("purchase.kept")).font(.body).foregroundStyle(Palette.muted)
                Rule()
                if purchases.entitlement?.purchasedPro == true {
                    Text(L.t("purchase.unlocked")).font(.headline).foregroundStyle(Palette.accent)
                } else {
                    offer
                }
                QuietButton(title: L.t("settings.restore"), id: "paywall.restore") {
                    Task { await purchases.restore() }
                }.disabled(purchases.busy)
            }
        }
        .task { await purchases.loadProducts() }
        .modifier(PurchaseNotice(purchases: purchases))
    }

    private var offer: some View {
        let pro = purchases.products.first { $0.id == purchases.proID }
        let trial = purchases.products.first { $0.id == purchases.trialID }
        let days = purchases.trialDays
        return VStack(alignment: .leading, spacing: 11) {
            if days > 0 {
                Text(L.f("purchase.days", Int64(days))).font(.headline).foregroundStyle(Palette.accent)
            } else {
                Text(L.t("purchase.expired")).font(.headline)
            }
            if let price = pro?.displayPrice ?? (Launch.testing ? L.t("purchase.testPrice") : nil) {
                ActionButton(title: L.f("purchase.buy", price), id: "paywall.buy") {
                    Task { await purchases.purchase(purchases.proID) }
                }.disabled(purchases.busy)
            } else if purchases.loadingProducts {
                ProgressView(L.t("purchase.loading"))
            } else {
                Text(L.t("purchase.unavailable")).foregroundStyle(Palette.muted)
                ActionButton(title: L.t("common.retry"), id: "paywall.retry", prominent: false) {
                    Task { await purchases.loadProducts() }
                }
            }
            if days > 0 && purchases.entitlement?.trialClaimedAt == nil && (trial != nil || Launch.testing) {
                ActionButton(title: L.t("purchase.claim"), id: "paywall.trial", prominent: false) {
                    Task { await purchases.purchase(purchases.trialID) }
                }.disabled(purchases.busy)
            }
            Text(L.t("purchase.once")).font(.footnote).foregroundStyle(Palette.muted)
        }
    }
}

private struct PurchaseNotice: ViewModifier {
    @ObservedObject var purchases: Purchases
    func body(content: Content) -> some View {
        content.alert(L.t("common.notice"), isPresented: Binding(
            get: { purchases.message != nil }, set: { if !$0 { purchases.message = nil } }
        )) {
            Button(L.t("common.close"), role: .cancel) { purchases.message = nil }
                .accessibilityIdentifier("purchase.closeNotice")
        } message: {
            Text(L.t(purchases.message ?? "purchase.failed"))
        }
    }
}
