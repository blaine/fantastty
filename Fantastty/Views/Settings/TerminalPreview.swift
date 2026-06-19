import SwiftUI

/// A miniature terminal that renders a realistic sample in a given font and a
/// set of theme colors — a truthful preview of what a font or theme choice will
/// look like. Used full-size in the font section and `compact` as the thumbnails
/// in the theme list.
struct TerminalPreview: View {
    let font: Font
    let background: Color
    let foreground: Color
    let palette: [Color]
    var compact: Bool = false

    private func ansi(_ index: Int) -> Color {
        palette.indices.contains(index) ? palette[index] : foreground
    }

    private var pad: CGFloat { compact ? 8 : 14 }
    private var corner: CGFloat { compact ? 7 : 10 }
    private var dot: CGFloat { compact ? 6 : 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack(spacing: compact ? 4 : 6) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.35)).frame(width: dot, height: dot)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: dot, height: dot)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: dot, height: dot)
                Spacer()
            }
            .padding(.bottom, compact ? 1 : 4)

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
                    + Text("up to date ✓").foregroundColor(ansi(6))
            }
            .font(font)
            .lineLimit(1)
        }
        .padding(pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: corner).fill(background))
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(.white.opacity(0.08)))
    }
}
