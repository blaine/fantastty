import SwiftUI

/// Terminal color-theme picker. Each row is a light/dark *pair* (e.g. "Gruvbox"),
/// previewed as two miniature terminals in the pair's real colors. Picking a
/// pair writes a `theme = light:…,dark:…` directive into the appearance overlay,
/// so Ghostty follows the system appearance between the two automatically.
struct AppearanceThemeSection: View {
    @EnvironmentObject private var ghosttyApp: Ghostty.App

    @State private var query = ""
    @State private var selectedBase: String? = AppearanceManager.shared.themePairBase

    private let pairs = ThemeCatalog.shared.pairs
    private let defaultRowID = "__default__"

    private var filtered: [ThemePair] {
        guard !query.isEmpty else { return pairs }
        return pairs.filter { $0.base.localizedCaseInsensitiveContains(query) }
    }

    /// Thumbnails render in the chosen terminal font, so a theme preview also
    /// reflects the font choice.
    private var thumbnailFont: Font {
        Font(AppearanceFonts.font(
            family: AppearanceManager.shared.fontFamily ?? "",
            style: AppearanceManager.shared.fontStyle ?? "",
            size: 11
        ))
    }

    var body: some View {
        Section("Terminal Theme") {
            VStack(spacing: 10) {
                searchField

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            DefaultThemeRow(
                                font: thumbnailFont,
                                background: ghosttyApp.config.backgroundColor,
                                foreground: ghosttyApp.config.foregroundColor ?? .white,
                                palette: ghosttyApp.config.ansiPalette,
                                isSelected: selectedBase == nil
                            ) { apply(nil) }
                                .id(defaultRowID)

                            ForEach(filtered) { pair in
                                ThemePairRow(
                                    pair: pair,
                                    font: thumbnailFont,
                                    isSelected: selectedBase == pair.base
                                ) { apply(pair.base) }
                                    .id(pair.base)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: 320)
                    .onAppear {
                        guard let selectedBase else { return }
                        proxy.scrollTo(selectedBase, anchor: .center)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter themes", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(.textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.08)))
    }

    private func apply(_ base: String?) {
        selectedBase = base
        AppearanceManager.shared.themePairBase = base
        AppearanceManager.shared.writeOverlay()
        ghosttyApp.reloadConfig()
    }
}

/// One pair row: the base name, a selection indicator, and two mini terminals —
/// the light and dark variants — in their real colors.
private struct ThemePairRow: View {
    let pair: ThemePair
    let font: Font
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(pair.base)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                variant("Light", systemImage: "sun.max.fill", theme: pair.light)
                variant("Dark", systemImage: "moon.fill", theme: pair.dark)
            }
        }
        .modifier(SelectionChrome(isSelected: isSelected))
        .onTapGesture(perform: onSelect)
    }

    private func variant(_ label: String, systemImage: String, theme: GhosttyTheme) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TerminalPreview(
                font: font,
                background: theme.background.color,
                foreground: theme.foreground.color,
                palette: theme.palette.map(\.color),
                compact: true
            )
        }
        .frame(maxWidth: .infinity)
    }
}

/// The "Default" row, which clears any theme choice and previews the base
/// config's current colors.
private struct DefaultThemeRow: View {
    let font: Font
    let background: Color
    let foreground: Color
    let palette: [Color]
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Default")
                    .fontWeight(.medium)
                Text("· follows your base config")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            TerminalPreview(
                font: font,
                background: background,
                foreground: foreground,
                palette: palette,
                compact: true
            )
        }
        .modifier(SelectionChrome(isSelected: isSelected))
        .onTapGesture(perform: onSelect)
    }
}

/// Selection framing shared by the theme rows.
private struct SelectionChrome: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.white.opacity(0.06),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
    }
}
