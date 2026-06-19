import SwiftUI
import AppKit

/// Terminal font control: a live terminal preview (rendered in the chosen font
/// using the actual current theme colors), the current font description, and a
/// "Change…" button that opens the native macOS font panel — the same pattern
/// Terminal.app uses. The panel handles family, typeface, and size together.
/// Choices apply to every open surface immediately via a config reload.
struct AppearanceFontSection: View {
    @EnvironmentObject private var ghosttyApp: Ghostty.App

    @State private var family: String = AppearanceManager.shared.fontFamily ?? ""
    @State private var style: String = AppearanceManager.shared.fontStyle ?? ""
    @State private var size: Double = AppearanceManager.shared.fontSize > 0
        ? AppearanceManager.shared.fontSize : 13

    private var fontDescription: String {
        let points = Int(size.rounded())
        guard !family.isEmpty else { return "System Monospace · \(points) pt" }
        let face = style.isEmpty ? "Regular" : style
        return "\(family) · \(face) · \(points) pt"
    }

    var body: some View {
        Section("Terminal Font") {
            VStack(alignment: .leading, spacing: 12) {
                TerminalPreview(
                    font: Font(AppearanceFonts.font(family: family, style: style, size: size)),
                    background: ghosttyApp.config.backgroundColor,
                    foreground: ghosttyApp.config.foregroundColor ?? .white,
                    palette: ghosttyApp.config.ansiPalette
                )

                HStack(spacing: 12) {
                    Text(fontDescription)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    FontChangeButton(
                        currentFont: { AppearanceFonts.font(family: family, style: style, size: size) },
                        onPicked: { newFamily, newStyle, newSize in
                            family = newFamily
                            style = newStyle
                            size = newSize
                            apply()
                        }
                    )
                    .frame(width: 86, height: 22)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func apply() {
        AppearanceManager.shared.fontFamily = family.isEmpty ? nil : family
        AppearanceManager.shared.fontStyle = style.isEmpty ? nil : style
        AppearanceManager.shared.fontSize = size
        AppearanceManager.shared.writeOverlay()
        ghosttyApp.reloadConfig()
    }
}

/// A miniature terminal that renders a realistic sample in the chosen font and
/// the live theme colors — a truthful preview of what the choice will look like.
private struct TerminalPreview: View {
    let font: Font
    let background: Color
    let foreground: Color
    let palette: [Color]

    private func ansi(_ index: Int) -> Color {
        palette.indices.contains(index) ? palette[index] : foreground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.35)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 10, height: 10)
                Spacer()
            }
            .padding(.bottom, 4)

            Group {
                Text("~/dev ").foregroundColor(ansi(4))
                    + Text("$ ").foregroundColor(ansi(2))
                    + Text("ls -a").foregroundColor(foreground)
                Text(".git   ").foregroundColor(ansi(8))
                    + Text("README.md   ").foregroundColor(foreground)
                    + Text("src   ").foregroundColor(ansi(4))
                    + Text("assets").foregroundColor(ansi(4))
                Text("~/dev ").foregroundColor(ansi(4))
                    + Text("$ ").foregroundColor(ansi(2))
                    + Text("git status").foregroundColor(foreground)
                Text("On branch ").foregroundColor(foreground)
                    + Text("main").foregroundColor(ansi(2))
                    + Text(" · ").foregroundColor(ansi(8))
                    + Text("everything up to date ✓").foregroundColor(ansi(6))
            }
            .font(font)
            .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
        .help("Live preview using your current theme colors")
    }
}

/// A "Change…" button that opens the native macOS font panel and reports the
/// chosen family / typeface / size back through `onPicked`.
private struct FontChangeButton: NSViewRepresentable {
    var currentFont: () -> NSFont
    var onPicked: (_ family: String, _ style: String, _ size: Double) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = FontPanelButton(title: "Change…", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(FontPanelButton.openFontPanel)
        button.currentFontProvider = currentFont
        button.onPicked = onPicked
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        guard let button = nsView as? FontPanelButton else { return }
        button.currentFontProvider = currentFont
        button.onPicked = onPicked
    }
}

/// NSButton that owns the font-panel interaction. It becomes first responder so
/// the panel's `changeFont(_:)` reaches it, then maps the chosen NSFont to a
/// Ghostty font-family / font-style / font-size.
private final class FontPanelButton: NSButton, NSFontChanging {
    var currentFontProvider: (() -> NSFont)?
    var onPicked: ((String, String, Double) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    @objc func openFontPanel() {
        guard let window else { return }
        let manager = NSFontManager.shared
        manager.setSelectedFont(currentFontProvider?() ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
                                isMultiple: false)
        window.makeFirstResponder(self)
        manager.orderFrontFontPanel(self)
    }

    func changeFont(_ sender: NSFontManager?) {
        guard let manager = sender else { return }
        let base = currentFontProvider?() ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let chosen = manager.convert(base)
        let family = chosen.familyName ?? ""
        let face = (chosen.fontDescriptor.object(forKey: .face) as? String) ?? ""
        onPicked?(family, face, Double(chosen.pointSize))
    }

    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection, .face, .size]
    }
}

/// NSFont construction for the chosen family/style/size, with a system
/// monospace fallback.
enum AppearanceFonts {
    static func font(family: String, style: String, size: Double) -> NSFont {
        let pointSize = CGFloat(size > 0 ? size : 13)
        if !family.isEmpty {
            if !style.isEmpty,
               let members = NSFontManager.shared.availableMembers(ofFontFamily: family) {
                for member in members where (member.count > 1 ? member[1] as? String : nil) == style {
                    if let psName = member[0] as? String, let f = NSFont(name: psName, size: pointSize) {
                        return f
                    }
                }
            }
            if let f = NSFont(name: family, size: pointSize) { return f }
        }
        return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }
}
