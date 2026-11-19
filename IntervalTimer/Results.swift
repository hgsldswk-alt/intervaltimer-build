import CoreImage
import SwiftUI
import UIKit

struct SharePayload {
    let items: [Any]
    var files: [URL] = []
}

struct SystemShare: UIViewControllerRepresentable {
    let payload: SharePayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: payload.items, applicationActivities: nil)
        let files = payload.files
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task.detached(priority: .utility) {
                let folders = Set(files.map { $0.deletingLastPathComponent() })
                for file in files { try? FileManager.default.removeItem(at: file) }
                for folder in folders where folder.lastPathComponent.hasPrefix("IntervalTimer-Share-") {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct RecordsView: View {
    @EnvironmentObject private var model: AppModel
    let open: (WorkoutRecord) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageHeading(title: L.t("tab.records"))
                    .padding(.bottom, 22)
                if model.orderedRecords.isEmpty {
                    Text(L.t("records.empty")).foregroundStyle(Palette.muted)
                }
                ForEach(model.orderedRecords) { record in
                    Rule()
                    recordRow(record)
                }
            }
            .pageInsets()
            .padding(.bottom, 14)
        }
    }

    private func recordRow(_ record: WorkoutRecord) -> some View {
        Button {
            open(record)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.plan.name).font(.headline)
                    Text("\(date(record)) · \(L.t(record.completed ? "result.completed" : "result.early"))")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                Text(timerText(record.totalSeconds)).font(.headline.monospacedDigit())
                Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier("record.\(record.id.uuidString)")
    }

    private func date(_ record: WorkoutRecord) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = TimeZone(identifier: record.timeZoneID) ?? TimeZone(secondsFromGMT: 0)
        return formatter.string(from: record.startedAt)
    }
}

struct ResultView: View {
    @EnvironmentObject private var model: AppModel
    let record: WorkoutRecord
    let fromHistory: Bool
    let share: (WorkoutRecord, Bool) -> Void
    let back: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeading(title: L.t(record.completed ? "result.completed" : "result.early"),
                            subtitle: L.t("result.saved"))
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("result.title")
                ViewThatFits(in: .horizontal) {
                    ScoreCard(record: record, milestone: false).scaled(to: 304)
                    ScoreCard(record: record, milestone: false).scaled(to: 260)
                    ScoreCard(record: record, milestone: false).scaled(to: 232)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("result.card")
                HStack(spacing: 6) {
                    Text(L.t(model.copied == "result.copied" ? "result.copied" : "result.tags"))
                        .font(.caption).foregroundStyle(Palette.muted)
                    Spacer(minLength: 4)
                    QuietButton(title: L.t("result.copy"), id: "result.copy") {
                        model.copy(ScoreCard.caption(record, milestone: false), notice: "result.copied")
                    }
                }
                if let milestone = record.milestone {
                    Rule()
                    Text(L.f("result.milestone", Int64(milestone))).font(.headline)
                        .accessibilityIdentifier("result.milestone")
                    ActionButton(title: L.t("result.shareMilestone"), id: "result.shareMilestone", prominent: false) {
                        share(record, true)
                    }
                    QuietButton(title: L.t("result.copyMilestone"), id: "result.copyMilestone") {
                        model.copy(ScoreCard.caption(record, milestone: true), notice: "result.milestoneCopied")
                    }
                }
            }
            .pageInsets()
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 1) {
                ActionButton(title: L.t("result.share"), id: "result.share") { share(record, false) }
                QuietButton(title: L.t(fromHistory ? "result.backRecords" : "result.back"), id: "result.back", action: back)
            }
            .padding(.horizontal, Palette.inset)
            .padding(.top, 9)
            .background(Palette.background)
        }
    }
}

struct ScoreCard: View {
    let record: WorkoutRecord
    let milestone: Bool
    private static let width: CGFloat = 360
    private static let height: CGFloat = 450
    private static let qrPixels = 195
    private static let downloadCode = makeDownloadCode()
    private var count: Int? { milestone ? record.milestone : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(record.plan.name).font(.system(size: 22, weight: .bold)).lineLimit(2)
                .minimumScaleFactor(0.75)
            if !record.completed || count != nil {
                Text(count.map { L.f("result.milestone", Int64($0)) } ?? L.t("result.early"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.paperMuted)
                    .padding(.top, 4)
            }
            Text(timerText(record.totalSeconds))
                .font(.system(size: 82, weight: .bold)).monospacedDigit().tracking(-6)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.top, 20)
            Text(L.t("card.total")).font(.system(size: 14)).foregroundStyle(Palette.paperMuted)
            Rectangle().fill(Palette.paperMuted.opacity(0.34)).frame(height: 1)
                .padding(.top, 20).padding(.bottom, 13)
            HStack(spacing: 12) {
                stat("\(record.rounds)/\(record.plan.parameters.rounds)", label: L.t("card.rounds"))
                stat(timerText(record.workSeconds), label: L.t("card.work"))
            }
            Spacer(minLength: 10)
            HStack(alignment: .bottom, spacing: 9) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t(count != nil ? "card.milestoneTag" : "card.tag"))
                        .font(.system(size: 14, weight: .bold))
                    Text(L.t("app.name")).font(.system(size: 12)).foregroundStyle(Palette.paperMuted)
                }
                Spacer(minLength: 0)
                VStack(spacing: 4) {
                    if let image = Self.downloadCode {
                        Image(uiImage: image).resizable().interpolation(.none)
                            .frame(width: 65, height: 65)
                    } else {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.paperMuted.opacity(0.36),
                                                                       style: StrokeStyle(lineWidth: 1, dash: [3]))
                            .frame(width: 65, height: 65)
                    }
                    Text(L.t(Self.downloadCode == nil ? "card.placeholder" : "card.download"))
                        .font(.system(size: 10)).foregroundStyle(Palette.paperMuted)
                }
            }
        }
        .padding(23)
        .frame(width: Self.width, height: Self.height)
        .foregroundStyle(Palette.paperInk)
        .background(Palette.paper)
    }

    private func stat(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 25, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 14)).foregroundStyle(Palette.paperMuted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    func scaled(to width: CGFloat) -> some View {
        let factor = width / Self.width
        return clipShape(RoundedRectangle(cornerRadius: 18))
            .scaleEffect(factor)
            .frame(width: width, height: Self.height * factor)
    }

    static func caption(_ record: WorkoutRecord, milestone: Bool) -> String {
        if milestone, let count = record.milestone { return L.f("share.milestone", Int64(count)) }
        let time = L.f("share.duration", Int64(record.totalSeconds / 60), Int64(record.totalSeconds % 60))
        return L.f(record.completed ? "share.caption" : "share.earlyCaption", Int64(record.rounds), time)
    }

    @MainActor static func image(record: WorkoutRecord, milestone: Bool) -> UIImage? {
        let renderer = ImageRenderer(content: ScoreCard(record: record, milestone: milestone))
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }

    private static func makeDownloadCode() -> UIImage? {
        guard let url = Launch.appStoreURL,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let source = CIContext().createCGImage(output, from: output.extent),
              let context = CGContext(data: nil, width: qrPixels, height: qrPixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let module = qrPixels / (source.width + 8)
        guard module > 0 else { return nil }
        let drawn = source.width * module
        let inset = (qrPixels - drawn) / 2
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: qrPixels, height: qrPixels))
        context.interpolationQuality = .none
        context.draw(source, in: CGRect(x: inset, y: inset, width: drawn, height: drawn))
        guard let image = context.makeImage() else { return nil }
        return UIImage(cgImage: image, scale: 3, orientation: .up)
    }
}
