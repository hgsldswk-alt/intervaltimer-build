import SwiftUI

enum Palette {
    static let background = Color(red: 20/255, green: 22/255, blue: 24/255)
    static let surface = Color(red: 30/255, green: 33/255, blue: 34/255)
    static let line = Color(red: 56/255, green: 61/255, blue: 61/255)
    static let text = Color(red: 244/255, green: 245/255, blue: 241/255)
    static let muted = Color(red: 172/255, green: 176/255, blue: 170/255)
    static let accent = Color(red: 200/255, green: 239/255, blue: 115/255)
    static let accentInk = Color(red: 26/255, green: 33/255, blue: 19/255)
    static let paper = Color(red: 242/255, green: 243/255, blue: 237/255)
    static let paperInk = Color(red: 32/255, green: 37/255, blue: 29/255)
    static let paperMuted = Color(red: 79/255, green: 87/255, blue: 73/255)
    static let inset: CGFloat = 23
}

struct PageHeading: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title.bold()).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActionButton: View {
    let title: String
    let id: String
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 55)
                .background(prominent ? Palette.accent : Color.clear, in: RoundedRectangle(cornerRadius: 15))
                .overlay {
                    if !prominent { RoundedRectangle(cornerRadius: 15).strokeBorder(Palette.line) }
                }
                .foregroundStyle(prominent ? Palette.accentInk : Palette.text)
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier(id)
    }
}

struct QuietButton: View {
    let title: String
    let id: String
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(accent ? Palette.accent : Palette.text)
                .padding(.horizontal, 7)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier(id)
    }
}

struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? (configuration.isPressed ? 0.70 : 1) : 0.42)
    }
}

struct Rule: View {
    var body: some View { Rectangle().fill(Palette.line).frame(height: 1).accessibilityHidden(true) }
}

struct SheetFrame<Content: View>: View {
    let title: String
    let id: String
    let close: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(id)
                Spacer(minLength: 8)
                QuietButton(title: L.t("common.close"), id: "sheet.close", action: close)
            }
            .padding(.bottom, 12)
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
                .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, Palette.inset)
        .padding(.top, 25)
        .padding(.bottom, 12)
        .foregroundStyle(Palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.background)
        .presentationDragIndicator(.visible)
    }
}

extension View {
    func pageInsets() -> some View {
        padding(.horizontal, Palette.inset).padding(.top, 16)
    }
}
