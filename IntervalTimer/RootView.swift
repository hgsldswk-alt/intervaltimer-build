import SwiftUI
import StoreKit
import UniformTypeIdentifiers

struct RootView: View {
    enum Tab: String, CaseIterable {
        case timer, records, settings
        var icon: String {
            switch self {
            case .timer: "stopwatch"
            case .records: "list.bullet.rectangle"
            case .settings: "gearshape"
            }
        }
    }

    enum Route: Identifiable {
        case edit(Plan?), transfer(Plan?), share(Plan), paywall, privacy, activity(SharePayload)
        var id: String {
            switch self {
            case .edit: "edit"
            case .transfer: "transfer"
            case .share: "share"
            case .paywall: "paywall"
            case .privacy: "privacy"
            case .activity: "activity"
            }
        }
    }

    @ObservedObject var purchases: Purchases
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.requestReview) private var requestReview
    @State private var tab = Tab.timer
    @State private var historicalRecord: WorkoutRecord?
    @State private var route: Route?
    @State private var pendingShare: SharePayload?
    @State private var readingID = UUID()
    @State private var initialRouteHandled = false
    @State private var returnedToIdleHome = false
    @State private var preparingShare = false

    private var ratingEligible: Bool {
        scene == .active && returnedToIdleHome && model.ratingPending && tab == .timer
            && model.snapshot == nil && model.result == nil && historicalRecord == nil
            && route == nil && pendingShare == nil && !preparingShare && model.message == nil && !model.busy
    }

    var body: some View {
        content
            .foregroundStyle(Palette.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background.ignoresSafeArea())
            .tint(Palette.accent)
            .sheet(item: $route, onDismiss: presentPendingShare) { item in
                sheet(item).modifier(WorkoutErrorNotice(model: model))
            }
            .overlay(alignment: .top) {
                if let copied = model.copied, route == nil {
                    Text(L.t(copied)).font(.subheadline.weight(.semibold))
                        .padding(.vertical, 8).padding(.horizontal, 16)
                        .background(Palette.surface, in: Capsule())
                        .padding(.top, 5).allowsHitTesting(false)
                }
            }
            .modifier(WorkoutErrorNotice(model: model, enabled: route == nil))
            .task {
                await model.didChangeScene(scene)
                await model.initialize()
                guard !initialRouteHandled else { return }
                initialRouteHandled = true
                if Launch.flag("-paywall") { route = .paywall }
                if Launch.flag("-test-file") { await openFixtureFile() }
            }
            .onChange(of: scene) { _, phase in Task { await model.didChangeScene(phase) } }
            .onOpenURL(perform: readFile)
            .task(id: model.snapshot?.id) {
                guard model.snapshot != nil else { return }
                while !Task.isCancelled {
                    await model.tick()
                    try? await Task.sleep(for: .milliseconds(180))
                }
            }
            .task(id: ratingEligible) {
                guard ratingEligible else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, ratingEligible else { return }
                if !Launch.testing { requestReview() }
                model.markRatingRequested()
            }
    }

    @ViewBuilder private var content: some View {
        switch model.loadState {
        case .loading:
            ProgressView(L.t("common.loading")).tint(Palette.accent)
        case .failed:
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: L.t("error.load"))
                Text(L.t("error.loadHelp")).foregroundStyle(Palette.muted)
                ActionButton(title: L.t("common.retry"), id: "load.retry") {
                    Task { await model.initialize() }
                }
            }
            .pageInsets()
        case .ready:
            if let snapshot = model.snapshot {
                ActiveView(session: snapshot)
            } else if let record = model.result ?? historicalRecord {
                ResultView(record: record, fromHistory: model.result == nil, share: shareScore) {
                    if model.result != nil {
                        model.result = nil
                        tab = .timer
                        returnedToIdleHome = record.milestone == nil
                    } else {
                        historicalRecord = nil
                    }
                }
            } else {
                VStack(spacing: 0) {
                    tabContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    tabBar
                }
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .timer:
            HomeView {
                openEditor(model.selected)
            } share: {
                route = .share(model.selected)
            } create: {
                openEditor(nil)
            } importPlan: {
                route = .transfer(nil)
            }
        case .records:
            RecordsView { historicalRecord = $0 }
        case .settings:
            SettingsView(purchases: purchases) { route = .paywall } privacy: { route = .privacy }
                export: { exportPlans(model.data.allPlans) } recommend: { recommend() }
        }
    }

    private var tabBar: some View {
        VStack(spacing: 3) {
            Rule()
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button {
                        tab = item
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon).font(.system(size: 17, weight: .medium))
                                .accessibilityHidden(true)
                            Text(L.t("tab." + item.rawValue)).font(.caption.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity, minHeight: 47)
                        .contentShape(Rectangle())
                        .foregroundStyle(tab == item ? Palette.accent : Palette.muted)
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityIdentifier("tab." + item.rawValue)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, Palette.inset)
        .background(Palette.background)
    }

    private func openEditor(_ plan: Plan?) {
        guard !model.busy else { return }
        if purchases.hasPro { route = .edit(plan) }
        else if purchases.entitlement != nil { route = .paywall }
    }

    @ViewBuilder private func sheet(_ route: Route) -> some View {
        switch route {
        case .edit(let plan):
            PlanEditor(plan: plan) { self.route = nil }
        case .transfer(let file):
            ImportSheet(file: file) {
                self.route = nil
                returnedToIdleHome = false
                tab = .timer
                historicalRecord = nil
            } close: { self.route = nil }
        case .share(let plan):
            PlanShareSheet(plan: plan) {
                exportPlans([plan], replacingSheet: true)
            } close: { self.route = nil }
            .presentationDetents([.medium, .large])
        case .paywall:
            PaywallView(purchases: purchases) { self.route = nil }
        case .privacy:
            SheetFrame(title: L.t("settings.privacy"), id: "privacy.title", close: { self.route = nil }) {
                Text(L.t("privacy.body")).font(.body).foregroundStyle(Palette.muted)
            }
        case .activity(let payload):
            SystemShare(payload: payload)
        }
    }

    private func readFile(_ url: URL) {
        guard url.isFileURL else { return }
        let ticket = UUID()
        readingID = ticket
        Task {
            let parameters = await Task.detached(priority: .userInitiated) { try? PlanFiles.read(url) }.value
            guard readingID == ticket else { return }
            guard let parameters else { model.message = "import.invalid"; return }
            route = .transfer(Plan(id: UUID(), parameters: parameters))
        }
    }

    private func exportPlans(_ plans: [Plan], replacingSheet: Bool = false) {
        guard !preparingShare else { return }
        preparingShare = true
        Task {
            defer { preparingShare = false }
            let urls = await Task.detached(priority: .userInitiated) { try? PlanFiles.export(plans) }.value
            guard let urls else { model.message = "error.export"; return }
            let payload = SharePayload(items: urls, files: urls)
            if replacingSheet && route != nil {
                pendingShare = payload
                route = nil
            } else {
                route = .activity(payload)
            }
        }
    }

    private func presentPendingShare() {
        guard let payload = pendingShare else { return }
        pendingShare = nil
        route = .activity(payload)
    }

    private func recommend() {
        var items: [Any] = [L.t("share.recommend")]
        if let url = Launch.appStoreURL { items.append(url) }
        route = .activity(SharePayload(items: items))
    }

    private func shareScore(_ record: WorkoutRecord, _ milestone: Bool) {
        guard !preparingShare else { return }
        preparingShare = true
        Task { @MainActor in
            defer { preparingShare = false }
            guard let image = ScoreCard.image(record: record, milestone: milestone) else {
                model.message = "error.export"
                return
            }
            let file = await Task.detached(priority: .userInitiated) { () -> URL? in
                guard let bytes = image.pngData() else { return nil }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Interval-\(UUID().uuidString).png")
                do {
                    try bytes.write(to: url, options: .atomic)
                    return url
                } catch { return nil }
            }.value
            guard let file else { model.message = "error.export"; return }
            route = .activity(SharePayload(items: [file, ScoreCard.caption(record, milestone: milestone)], files: [file]))
        }
    }

    private func openFixtureFile() async {
        let urls = await Task.detached {
            try? PlanFiles.export([Plan(id: UUID(), parameters: PlanParameters(name: "File fixture", work: 5,
                                                                                rounds: 2, prepare: 0))])
        }.value
        if let url = urls?.first { readFile(url) }
    }
}

private struct WorkoutErrorNotice: ViewModifier {
    @ObservedObject var model: AppModel
    var enabled = true

    func body(content: Content) -> some View {
        content.alert(L.t("common.notice"), isPresented: Binding(
            get: { enabled && model.message != nil }, set: { if !$0 { model.dismissError() } }
        )) {
            if model.finishBlocked {
                Button(L.t("common.retry")) { Task { await model.retrySave() } }
                    .accessibilityIdentifier("error.retry")
            }
            Button(L.t("common.close"), role: .cancel) { model.dismissError() }
                .accessibilityIdentifier("error.close")
        } message: {
            Text(L.t(model.message ?? "error.save"))
        }
    }
}
