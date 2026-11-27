import SwiftUI
import UniformTypeIdentifiers

struct PlanEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var name: String
    @State private var work: String
    @State private var rest: String
    @State private var rounds: String
    @State private var prepare: String
    @State private var cooldown: String
    @State private var expanded: Bool
    @FocusState private var focused: Bool
    let plan: Plan?
    let close: () -> Void

    init(plan: Plan?, close: @escaping () -> Void) {
        self.plan = plan
        self.close = close
        let value = plan?.portableParameters ?? PlanParameters(name: "")
        _name = State(initialValue: value.name)
        _work = State(initialValue: String(value.work))
        _rest = State(initialValue: String(value.rest))
        _rounds = State(initialValue: String(value.rounds))
        _prepare = State(initialValue: String(value.prepare))
        _cooldown = State(initialValue: String(value.cooldown))
        _expanded = State(initialValue: value.prepare != 10 || value.cooldown != 0)
    }

    private var parameters: PlanParameters {
        PlanParameters(name: name, work: Int(work) ?? -1, rest: Int(rest) ?? -1, rounds: Int(rounds) ?? -1,
                       prepare: Int(prepare) ?? -1, cooldown: Int(cooldown) ?? -1)
    }

    var body: some View {
        SheetFrame(title: L.t(plan == nil ? "editor.new" : "editor.edit"), id: "editor.title", close: close) {
            VStack(alignment: .leading, spacing: 12) {
                field("editor.name", text: $name, numeric: false)
                field("editor.work", text: $work)
                field("editor.rest", text: $rest)
                field("editor.rounds", text: $rounds)
                Rule()
                Button {
                    expanded.toggle()
                } label: {
                    HStack {
                        Text(L.t("editor.extra")).font(.subheadline.bold())
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityIdentifier("editor.extra")
                if expanded {
                    field("editor.prepare", text: $prepare)
                    field("editor.cooldown", text: $cooldown)
                }
                Rule()
                Text(L.f("editor.total", parameters.numbersValid ? timerText(parameters.total) : "—"))
                    .font(.headline.monospacedDigit())
                    .accessibilityIdentifier("editor.total")
                if !parameters.isValid {
                    Text(L.t(!parameters.numbersValid ? "editor.ranges"
                             : parameters.total > 7_200 ? "editor.tooLong" : "editor.nameRule"))
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
                ActionButton(title: L.t("editor.save"), id: "editor.save") {
                    focused = false
                    Task { if await model.save(parameters, editing: plan) { close() } }
                }
                .disabled(!parameters.isValid || model.busy)
                .padding(.top, 4)
            }
        }
    }

    private func field(_ key: String, text: Binding<String>, numeric: Bool = true) -> some View {
        HStack(spacing: 12) {
            Text(L.t(key)).font(.subheadline).foregroundStyle(Palette.muted)
            TextField(L.t(key), text: text)
                .keyboardType(numeric ? .numberPad : .default)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier(key)
                .focused($focused)
        }
    }
}

struct ImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var preview: PlanParameters?
    @State private var invalid = false
    @State private var picking = false
    @State private var pasteValue = ""
    @State private var previewReading = UUID()
    let file: Plan?
    let imported: () -> Void
    let close: () -> Void

    init(file: Plan?, imported: @escaping () -> Void, close: @escaping () -> Void) {
        self.file = file
        self.imported = imported
        self.close = close
        _preview = State(initialValue: file?.parameters)
    }

    var body: some View {
        SheetFrame(title: L.t("import.title"), id: "import.title", close: close) {
            VStack(alignment: .leading, spacing: 14) {
                if let preview {
                    Text(preview.name).font(.title2.bold()).accessibilityIdentifier("import.preview")
                    Text(summary(preview)).foregroundStyle(Palette.muted)
                    Text(L.f("import.extras", Int64(preview.prepare), Int64(preview.cooldown)))
                        .font(.footnote).foregroundStyle(Palette.muted)
                    if model.snapshot == nil {
                        ActionButton(title: L.t("import.start"), id: "import.start") { commit(preview, start: true) }
                            .disabled(model.busy)
                    } else {
                        Text(L.t("import.active")).font(.footnote).foregroundStyle(Palette.muted)
                    }
                    ActionButton(title: L.t("import.only"), id: "import.only", prominent: model.snapshot != nil) {
                        commit(preview, start: false)
                    }.disabled(model.busy)
                } else {
                    Text(L.t("import.instruction")).foregroundStyle(Palette.muted)
                    PasteButton(payloadType: String.self) { values in
                        previewReading = UUID()
                        if let value = values.first { decode(value) }
                    }
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("import.paste")
                    ActionButton(title: L.t("import.file"), id: "import.file", prominent: false) { picking = true }
                    if Launch.testing {
                        TextField(L.t("import.code"), text: $pasteValue).accessibilityIdentifier("import.testValue")
                        ActionButton(title: L.t("import.code"), id: "import.testCode", prominent: false) {
                            previewReading = UUID()
                            decode(ProcessInfo.processInfo.environment["INTERVAL_TEST_TEXT"] ?? pasteValue)
                        }
                    }
                }
                if invalid {
                    Text(L.t("import.invalid")).font(.footnote).foregroundStyle(Palette.muted)
                        .accessibilityIdentifier("import.invalid")
                }
            }
        }
        .id(file?.id)
        .onChange(of: file?.id) { _, _ in
            previewReading = UUID()
            preview = file?.parameters
            invalid = false
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.intervalPlan]) { result in
            guard case .success(let url) = result else { return }
            let ticket = UUID()
            previewReading = ticket
            Task {
                let value = await Task.detached(priority: .userInitiated) { try? PlanFiles.read(url) }.value
                guard previewReading == ticket else { return }
                preview = value
                invalid = value == nil
            }
        }
    }

    private func decode(_ value: String) {
        preview = try? PlanTransfer.decodeCode(value)
        invalid = preview == nil
    }

    private func summary(_ p: PlanParameters) -> String {
        L.f("import.summary", Int64(p.work), Int64(p.rest), Int64(p.rounds), timerText(p.total))
    }

    private func commit(_ parameters: PlanParameters, start: Bool) {
        Task { if await model.importPlan(parameters, start: start) { imported() } }
    }
}

struct PlanShareSheet: View {
    @EnvironmentObject private var model: AppModel
    let plan: Plan
    let export: () -> Void
    let close: () -> Void

    var body: some View {
        SheetFrame(title: L.t("planShare.title"), id: "planShare.title", close: close) {
            VStack(alignment: .leading, spacing: 10) {
                Text(plan.name).font(.headline)
                Text(L.t("planShare.help")).font(.subheadline).foregroundStyle(Palette.muted)
                    .padding(.bottom, 4)
                ActionButton(title: L.t("planShare.file"), id: "planShare.file", action: export)
                ActionButton(title: L.t("planShare.copy"), id: "planShare.copy", prominent: false) {
                    guard let code = try? PlanTransfer.code(plan.portableParameters) else {
                        model.message = "error.export"
                        return
                    }
                    model.copy(L.t("planShare.instructions") + "\n" + code, notice: "planShare.copied")
                }
                if model.copied == "planShare.copied" {
                    Text(L.t("planShare.copied")).foregroundStyle(Palette.muted)
                        .font(.footnote).accessibilityIdentifier("planShare.copied")
                }
            }
        }
    }
}
