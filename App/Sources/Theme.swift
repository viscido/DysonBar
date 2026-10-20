import SwiftUI

/// Colors of the control panel. Follows the system appearance: a deep,
/// warm-black panel in dark mode and a soft paper-white one in light mode.
struct Palette {
    let background: Color      // panel
    let card: Color            // tiles, chips, slider track
    let cardStroke: Color      // hairline around cards
    let control: Color         // round buttons
    let textPrimary: Color
    let textSecondary: Color
    let heat: Color            // heating accent (airflow, slider, power glow)
    let cool: Color            // cooling / fan-only accent
    let good: Color            // air quality good, connected
    let warning: Color         // air quality poor, offline
    let trackStart: Color      // slider fill gradient, left
    let trackEnd: Color        // slider fill gradient, at the thumb
    let thumb: Color
    let deviceBody: Color      // illustrated purifier
    let deviceShade: Color
    let deviceDetail: Color

    static let dark = Palette(
        background: Color(red: 0.055, green: 0.055, blue: 0.06),
        card: Color(white: 0.115),
        cardStroke: Color.white.opacity(0.07),
        control: Color(white: 0.15),
        textPrimary: Color(white: 0.95),
        textSecondary: Color(white: 0.56),
        heat: Color(red: 0.93, green: 0.62, blue: 0.33),
        cool: Color(red: 0.62, green: 0.79, blue: 0.93),
        good: Color(red: 0.45, green: 0.80, blue: 0.55),
        warning: Color(red: 0.95, green: 0.62, blue: 0.30),
        trackStart: Color(red: 0.36, green: 0.33, blue: 0.30),
        trackEnd: Color(red: 0.78, green: 0.72, blue: 0.64),
        thumb: Color(red: 0.96, green: 0.95, blue: 0.93),
        deviceBody: Color(white: 0.88),
        deviceShade: Color(white: 0.62),
        deviceDetail: Color(white: 0.30))

    static let light = Palette(
        background: Color(red: 0.965, green: 0.96, blue: 0.95),
        card: Color.white,
        cardStroke: Color.black.opacity(0.07),
        control: Color(red: 0.92, green: 0.915, blue: 0.90),
        textPrimary: Color(white: 0.09),
        textSecondary: Color(white: 0.43),
        heat: Color(red: 0.85, green: 0.48, blue: 0.17),
        cool: Color(red: 0.23, green: 0.56, blue: 0.81),
        good: Color(red: 0.20, green: 0.62, blue: 0.35),
        warning: Color(red: 0.85, green: 0.45, blue: 0.12),
        trackStart: Color(red: 0.91, green: 0.88, blue: 0.84),
        trackEnd: Color(red: 0.72, green: 0.64, blue: 0.54),
        thumb: Color.white,
        deviceBody: Color(white: 0.97),
        deviceShade: Color(white: 0.80),
        deviceDetail: Color(white: 0.45))

    static func forScheme(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.dark
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Apply once at the root of a panel: publishes the palette for the current
/// appearance to every child (`@Environment(\.palette) var palette`).
struct Themed: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.environment(\.palette, Palette.forScheme(scheme))
    }
}

extension View {
    func themed() -> some View { modifier(Themed()) }
}
