import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let edit: () -> Void
    let share: () -> Void
    let create: () -> Void
    let importPlan: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeading(title: L.t("app.name"), subtitle: L.t(
                    model.data.lastPlanID == model.selected.id ? "home.recent" : "home.selected"))
                    .padding(.bottom, 22)
                current
                heading
                    .padding(.top, 14)
                ForEach(model.alternatives) { plan in planRow(plan) }
            }
            .pageInsets()
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionButton(title: L.t("home.start"), id: "home.start") {
                Task { await model.start(model.selected) }
            }
            .disabled(model.busy)
            .padding(.horizontal, Palette.inset)
            .padding(.vertical, 10)
            .background(Palette.background)
        }
    }

    private var current: some View {
        let plan = model.selected
        let p = plan.parameters
        return VStack(alignment: .leading, spacing: 13) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { planName(plan); Spacer(minLength: 0); planActions }
                VStack(alignment: .leading, spacing: 1) { planName(plan); planActions }
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Metric(title: L.t("phase.work"), seconds: p.work)
                Metric(title: L.t("phase.rest"), seconds: p.rest)
            }.accessibilityElement(children: .contain)
            cadence(p)
            HStack {
                Text(L.f("home.planTotal", Int64(p.rounds), timerText(p.total))).fontWeight(.semibold)
                Spacer(minLength: 4)
                Text(p.cooldown > 0 ? L.f("home.prepareCooldown", Int64(p.prepare), Int64(p.cooldown))
                     : L.f("home.prepare", Int64(p.prepare)))
                    .foregroundStyle(Palette.muted)
            }
            .font(.footnote)
        }
        .padding(.horizontal, 17)
        .padding(.top, 10)
        .padding(.bottom, 17)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Palette.line) }
    }

    private func planName(_ plan: Plan) -> some View {
        Text(plan.name).font(.headline).lineLimit(2).accessibilityIdentifier("home.plan.name")
    }

    private var planActions: some View {
        HStack(spacing: 0) {
            QuietButton(title: L.t("home.edit"), id: "home.edit", action: edit)
            QuietButton(title: L.t("home.share"), id: "home.share", action: share)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var heading: some View {
        HStack(spacing: 3) {
            Text(L.t("home.other")).font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 3)
            QuietButton(title: L.t("import.title"), id: "home.import", action: importPlan)
            QuietButton(title: L.t("home.new"), id: "home.new", accent: true, action: create)
        }
    }

    private func planRow(_ plan: Plan) -> some View {
        VStack(spacing: 0) {
            Rule()
            Button {
                model.select(plan)
            } label: {
                HStack(spacing: 9) {
                    Text(plan.name).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(L.f("home.planTotal", Int64(plan.parameters.rounds), timerText(plan.parameters.total)))
                        .font(.footnote).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 9)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityIdentifier("plan.\(plan.id.uuidString)")
            .disabled(model.busy)
        }
    }

    private func cadence(_ parameters: PlanParameters) -> some View {
        GeometryReader { size in
            let available = max(0, size.size.width - (parameters.rest > 0 ? 4 : 0))
            let fraction = Double(parameters.work) / Double(parameters.work + parameters.rest)
            HStack(spacing: 4) {
                Capsule().fill(Palette.accent).frame(width: available * fraction)
                if parameters.rest > 0 { Capsule().fill(Palette.muted.opacity(0.52)) }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct Metric: View {
    let title: String
    let seconds: Int
    @ScaledMetric(relativeTo: .largeTitle) private var size = 66.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.subheadline).foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(seconds)").font(.system(size: size, weight: .bold))
                    .tracking(-size * 0.065).monospacedDigit().lineLimit(1).minimumScaleFactor(0.45)
                    .layoutPriority(1)
                Text(L.t("unit.seconds")).font(.caption2.weight(.medium)).foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L.f("metric.a11y", title, Int64(seconds))))
    }
}

struct ActiveView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirming = false
    let session: SessionSnapshot

    var body: some View {
        let timeline = Timeline(session.plan.parameters)
        let elapsed = model.elapsed
        let stage = timeline.stage(at: elapsed) ?? timeline.stages.last
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.plan.name).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        if session.running {
                            Text(L.t("timer.running")).font(.subheadline).foregroundStyle(Palette.muted)
                        }
                    }
                    Spacer(minLength: 10)
                    if let stage {
                        dial(timeline, stage: stage, elapsed: elapsed)
                            .frame(maxWidth: .infinity)
                    }
                    Spacer(minLength: 10)
                    if session.needsResume {
                        Text(L.t("timer.resumeSaved")).font(.footnote).foregroundStyle(Palette.muted)
                    }
                    if let stage { nextRow(timeline, stage: stage) }
                }
                .frame(minHeight: max(0, geometry.size.height - 24))
                .padding(.horizontal, Palette.inset)
                .padding(.vertical, 12)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 10) {
                ActionButton(title: L.t(model.finishBlocked ? "common.retry" : session.running ? "timer.pause" : "timer.resume"),
                             id: "timer.toggle") {
                    Task {
                        if model.finishBlocked { await model.retrySave() }
                        else { await model.togglePause() }
                    }
                }
                ActionButton(title: L.t("timer.end"), id: "timer.end", prominent: false) {
                    confirming = true
                }
                .frame(width: 112)
                .disabled(model.finishBlocked)
            }
            .disabled(model.busy)
            .padding(.horizontal, Palette.inset)
            .padding(.vertical, 15)
            .background(Palette.background)
        }
        .confirmationDialog(L.t("timer.confirmTitle"), isPresented: $confirming, titleVisibility: .visible) {
            Button(L.t("timer.confirmEnd"), role: .destructive) {
                Task { await model.finish(completed: false) }
            }.accessibilityIdentifier("timer.confirmEnd")
            Button(L.t("timer.cancelEnd"), role: .cancel) {}.accessibilityIdentifier("timer.cancelEnd")
        }
    }

    private func dial(_ timeline: Timeline, stage: Stage, elapsed: TimeInterval) -> some View {
        let remaining = timeline.remaining(in: stage, at: elapsed)
        let fraction = min(1.0, max(0.0, (Double(stage.end) - elapsed) / Double(stage.duration)))
        return VStack(spacing: 21) {
            Text(L.f("timer.round", Int64(stage.round), Int64(session.plan.parameters.rounds)))
                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
                .accessibilityIdentifier("timer.round")
            ZStack {
                Circle().strokeBorder(Palette.line, lineWidth: 5)
                Circle().trim(from: 0, to: fraction)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2.5)
                    .accessibilityHidden(true)
                VStack(spacing: 1) {
                    Text(stage.kind.title).font(.headline).foregroundStyle(Palette.accent)
                        .accessibilityIdentifier("timer.phase")
                    Text(String(format: "%02d:%02d", remaining / 60, remaining % 60))
                        .font(.system(size: 78, weight: .bold)).monospacedDigit().tracking(-5)
                        .lineLimit(1).minimumScaleFactor(0.55)
                        .accessibilityLabel(Text(L.f("timer.remaining", Int64(remaining))))
                        .accessibilityIdentifier("timer.remaining")
                    if !session.running {
                        Text(L.t("timer.paused")).font(.subheadline).foregroundStyle(Palette.muted)
                            .accessibilityIdentifier("timer.paused")
                    }
                }
                .padding(.horizontal, 21)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 278)
        }
    }

    private func nextRow(_ timeline: Timeline, stage: Stage) -> some View {
        let next = timeline.stages.dropFirst(stage.index + 1).first
        return VStack(spacing: 12) {
            Rule()
            HStack {
                Text(L.t("timer.next")).foregroundStyle(Palette.muted)
                Spacer()
                if let next { Text(L.f("notice.next", next.kind.title, Int64(next.duration))).fontWeight(.semibold) }
                else { Text(L.t("result.completed")).fontWeight(.semibold) }
            }.font(.subheadline)
            Rule()
        }
    }
}
