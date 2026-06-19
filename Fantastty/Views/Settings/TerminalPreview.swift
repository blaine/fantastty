import SwiftUI

/// A compact miniature terminal rendered in a given font and theme colors — a
/// truthful, tight preview of what a font or theme choice looks like. Used as
/// the thumbnails in the theme list.
struct TerminalPreview: View {
    let font: Font
    let background: Color
    let foreground: Color
    let palette: [Color]

    private func ansi(_ index: Int) -> Color {
        palette.indices.contains(index) ? palette[index] : foreground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.35)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 5, height: 5)
                Spacer()
            }

            Group {
                Text("~/dev ").foregroundColor(ansi(4))
                    + Text("$ ").foregroundColor(ansi(2))
                    + Text("ls -a").foregroundColor(foreground)
                Text("on ").foregroundColor(foreground)
                    + Text("main").foregroundColor(ansi(2))
                    + Text(" ✓").foregroundColor(ansi(6))
            }
            .font(font)
            .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
    }
}
