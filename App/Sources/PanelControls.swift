import SwiftUI
import AppKit

// MARK: - Shared styling

/// Card surface: `palette.card` fill, hairline stroke, very soft shadow in light mode.
private struct CardSurface: View {
    var radius: CGFloat = 14
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(palette.card)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(palette.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .light ? 0.05 : 0), radius: 6, y: 2)
    }
}

/// Hover brightening (darkening in light mode) and dimming when disabled.
private struct HoverHighlight: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .brightness(hovering && isEnabled ? (scheme == .dark ? 0.05 : -0.025) : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Plain button with hover highlight and a quick spring scale while pressed.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
            .modifier(HoverHighlight())
    }
}

// MARK: - PanelCard

/// Rounded card background used by every panel section (palette.card + hairline stroke).
/// Fills the available width; content is leading-aligned.
struct PanelCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardSurface())
    }
}

// MARK: - RoundIconButton

/// Circular control button (− / + / settings). Default 40 pt.
struct RoundIconButton: View {
    private let systemName: String
    private let size: CGFloat
    private let helpText: String?
    private let action: () -> Void
    /// Ring color shown when the button represents an open/selected state.
    fileprivate var highlight: Color?

    @Environment(\.palette) private var palette

    init(systemName: String, size: CGFloat = 40, help: String? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.size = size
        self.helpText = help
        self.action = action
    }

    private var accessibilityName: String {
        if let helpText { return helpText }
        switch systemName {
        case "minus": return "Decrease"
        case "plus": return "Increase"
        default: return systemName.replacingOccurrences(of: ".", with: " ")
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: max(10, size * 0.36), weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(palette.control)
                        .overlay(Circle().fill(palette.textPrimary.opacity(highlight == nil ? 0 : 0.07)))
                )
                .overlay(
                    Circle().strokeBorder(highlight ?? palette.cardStroke, lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(helpText ?? "")
        .accessibilityLabel(accessibilityName)
        .animation(.easeInOut(duration: 0.2), value: highlight != nil)
    }
}

private extension RoundIconButton {
    func highlighted(_ color: Color?) -> RoundIconButton {
        var copy = self
        copy.highlight = color
        return copy
    }
}

// MARK: - PowerButton

/// 44 pt power button; glows with `tint` when on.
struct PowerButton: View {
    private let isOn: Bool
    private let tint: Color
    private let action: () -> Void

    @Environment(\.palette) private var palette

    init(isOn: Bool, tint: Color, action: @escaping () -> Void) {
        self.isOn = isOn
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isOn ? tint : palette.textSecondary)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(palette.control)
                        .overlay(Circle().fill(tint.opacity(isOn ? 0.12 : 0)))
                )
                .overlay(
                    Circle().strokeBorder(isOn ? tint : palette.textSecondary.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: tint.opacity(isOn ? 0.55 : 0), radius: 10)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .animation(.easeInOut(duration: 0.3), value: isOn)
        .accessibilityLabel("Power")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - TemperatureSlider

/// [−]  track with gradient fill up to a pill thumb  [+]
///       min label                          max label
/// Dragging updates `value` live (snapped to `step`); `onCommit` fires once
/// on release, and on each −/+ press with the new value.
struct TemperatureSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let tint: Color
    private let onCommit: (Double) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var dragging = false

    private let buttonSize: CGFloat = 38
    private let trackHeight: CGFloat = 36
    private let thumbSize = CGSize(width: 22, height: 30)
    private let inset: CGFloat = 3

    init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, tint: Color,
         onCommit: @escaping (Double) -> Void) {
        self._value = value
        self.range = range
        self.step = step
        self.tint = tint
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                RoundIconButton(systemName: "minus", size: buttonSize, help: "Decrease") { bump(-1) }
                    .disabled(value <= range.lowerBound)
                track
                RoundIconButton(systemName: "plus", size: buttonSize, help: "Increase") { bump(1) }
                    .disabled(value >= range.upperBound)
            }
            HStack {
                Text(String(format: "%.0f°", range.lowerBound))
                Spacer()
                Text(String(format: "%.0f°", range.upperBound))
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, buttonSize + 10 + 6)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityHidden(true)
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let travel = max(1, width - 2 * inset - thumbSize.width)
            let thumbX = inset + travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(palette.control)
                Capsule()
                    .fill(LinearGradient(colors: [palette.trackStart, palette.trackEnd],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(
                        Capsule().fill(LinearGradient(colors: [tint.opacity(0.06), tint.opacity(0.28)],
                                                      startPoint: .leading, endPoint: .trailing))
                    )
                    .frame(width: thumbX + thumbSize.width + inset)
                RoundedRectangle(cornerRadius: thumbSize.width / 2, style: .continuous)
                    .fill(palette.thumb)
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .scaleEffect(dragging ? 1.06 : 1)
                    .offset(x: thumbX)
            }
            .frame(height: trackHeight)
            .overlay(
                // Circular style: a continuous curve at r = h/2 draws stray ticks.
                RoundedRectangle(cornerRadius: trackHeight / 2 - 0.5, style: .circular)
                    .strokeBorder(palette.cardStroke, lineWidth: 1)
            )
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard isEnabled else { return }
                        if !dragging { withAnimation(.spring(response: 0.2)) { dragging = true } }
                        let f = (g.location.x - inset - thumbSize.width / 2) / travel
                        let v = snapped(range.lowerBound + Double(min(1, max(0, f))) * span)
                        if v != value { value = v }
                    }
                    .onEnded { _ in
                        guard isEnabled else { return }
                        withAnimation(.spring(response: 0.2)) { dragging = false }
                        onCommit(value)
                    }
            )
        }
        .frame(height: trackHeight)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(dragging ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: value)
        .accessibilityElement()
        .accessibilityLabel("Temperature")
        .accessibilityValue(String(format: "%.0f°", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: bump(1)
            case .decrement: bump(-1)
            @unknown default: break
            }
        }
    }

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }

    private var fraction: CGFloat {
        CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
    }

    private func snapped(_ v: Double) -> Double {
        let s = step > 0 ? step : 1
        let n = ((v - range.lowerBound) / s).rounded()
        return min(range.upperBound, max(range.lowerBound, range.lowerBound + n * s))
    }

    private func bump(_ direction: Double) {
        let v = snapped(value + direction * step)
        value = v
        onCommit(v)
    }
}

// MARK: - ToggleChip

/// Pill card: icon, title, switch (like the reference's "Eco Mode").
struct ToggleChip: View {
    private let title: String
    private let systemImage: String
    private let isOn: Bool
    private let onToggle: (Bool) -> Void

    @Environment(\.palette) private var palette

    init(title: String, systemImage: String, isOn: Bool, onToggle: @escaping (Bool) -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isOn = isOn
        self.onToggle = onToggle
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { onToggle(!isOn) } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            Toggle(title, isOn: Binding(get: { isOn }, set: { onToggle($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(CardSurface())
        .modifier(HoverHighlight())
    }
}

// MARK: - ControlTile

struct TileOption: Identifiable, Hashable {
    let id: String
    let title: String
}

/// Square-ish tile: icon top-left, accessory top-right, title + value at the bottom.
struct ControlTile: View {
    enum Accessory {
        case none
        case dot(active: Bool)    // tap → onTap
        case menu(options: [TileOption], selectedID: String?, onSelect: (String) -> Void)
    }

    private let systemImage: String
    private let title: String
    private let value: String
    private let accessory: Accessory
    private let isActive: Bool
    private let onTap: (() -> Void)?

    @Environment(\.palette) private var palette

    init(systemImage: String, title: String, value: String, accessory: Accessory,
         isActive: Bool = false, onTap: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.value = value
        self.accessory = accessory
        self.isActive = isActive
        self.onTap = onTap
    }

    var body: some View {
        Button(action: activate) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isActive ? palette.heat : palette.textPrimary)
                        .frame(height: 20)
                    Spacer(minLength: 2)
                    accessoryView
                        .frame(height: 20)
                }
                Spacer(minLength: 4)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 84)
            .background(CardSurface())
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(.easeInOut(duration: 0.2), value: isActive)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .dot(let active):
            Circle()
                .fill(active ? palette.good : palette.textSecondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .shadow(color: palette.good.opacity(active ? 0.6 : 0), radius: 3)
        case .menu:
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var accessibilityValue: String {
        if case .dot(let active) = accessory { return "\(value), \(active ? "On" : "Off")" }
        return value
    }

    private func activate() {
        switch accessory {
        case .none, .dot:
            onTap?()
        case let .menu(options, selectedID, onSelect):
            TileMenuPresenter.popUp(options: options, selectedID: selectedID, onSelect: onSelect)
        }
    }
}

/// NSMenu whose items call back through a closure; retains its own target.
private final class ClosureMenu: NSMenu {
    final class Target: NSObject {
        let handler: (String) -> Void
        init(handler: @escaping (String) -> Void) { self.handler = handler }
        // Not `perform(_:)`: that name resolves to NSObject's `performSelector:`,
        // so AppKit would treat the menu item as a selector and the choice is lost.
        @objc func choose(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { handler(id) }
        }
    }
    var actionTarget: Target?
}

/// Pops up option menus for tiles (SwiftUI `Menu` would flatten the tile's label).
@MainActor
enum TileMenuPresenter {
    /// Keeps the last menu (and its target) alive until the next one is shown.
    private static var current: NSMenu?

    static func popUp(options: [TileOption], selectedID: String?, onSelect: @escaping (String) -> Void) {
        guard !options.isEmpty else { return }
        let menu = makeMenu(options: options, selectedID: selectedID, onSelect: onSelect)
        current = menu
        let selected = menu.items.first { $0.state == .on }
        menu.popUp(positioning: selected, at: NSEvent.mouseLocation, in: nil)
    }

    /// Separate from `popUp` so tests can fire items with `performActionForItem(at:)`.
    static func makeMenu(options: [TileOption], selectedID: String?,
                         onSelect: @escaping (String) -> Void) -> NSMenu {
        let menu = ClosureMenu(title: "")
        let target = ClosureMenu.Target(handler: onSelect)
        menu.actionTarget = target
        menu.autoenablesItems = false
        for option in options {
            let item = NSMenuItem(title: option.title,
                                  action: #selector(ClosureMenu.Target.choose(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = option.id
            item.isEnabled = true
            if option.id == selectedID { item.state = .on }
            menu.addItem(item)
        }
        return menu
    }
}

// MARK: - AirQualityStrip

enum AirQualityLevel { case good, fair, poor }

struct AirQualityItem: Identifiable {
    let id: String
    let label: String
    let value: String
    let level: AirQualityLevel?
}

/// One compact row of readings, e.g. "PM2.5 12 · VOC 3.4 · HCHO 0.012 · 45%".
struct AirQualityStrip: View {
    private let items: [AirQualityItem]

    @Environment(\.palette) private var palette

    init(items: [AirQualityItem]) {
        self.items = items
    }

    var body: some View {
        PanelCard(padding: 9) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle()
                            .fill(palette.cardStroke)
                            .frame(width: 1, height: 26)
                    }
                    cell(item)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func cell(_ item: AirQualityItem) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                if let level = item.level {
                    Circle()
                        .fill(color(for: level))
                        .frame(width: 5, height: 5)
                }
                Text(item.label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(item.value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.label)
        .accessibilityValue(item.value)
    }

    private func color(for level: AirQualityLevel) -> Color {
        switch level {
        case .good: return palette.good
        case .poor: return palette.warning
        case .fair:
            // Halfway between good and warning, nudged toward yellow.
            let good = NSColor(palette.good).usingColorSpace(.sRGB) ?? .systemGreen
            let warn = NSColor(palette.warning).usingColorSpace(.sRGB) ?? .systemOrange
            let mid = good.blended(withFraction: 0.55, of: warn) ?? warn
            let yellow = mid.blended(withFraction: 0.35, of: .systemYellow) ?? mid
            return Color(nsColor: yellow)
        }
    }
}

// MARK: - StatusFooter

/// Bottom bar: status icon + text on the left, settings button on the right.
struct StatusFooter: View {
    private let text: String
    private let systemImage: String
    private let tint: Color
    private let detailsOpen: Bool
    private let onToggleDetails: () -> Void

    @Environment(\.palette) private var palette

    init(text: String, systemImage: String, tint: Color, detailsOpen: Bool,
         onToggleDetails: @escaping () -> Void) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.detailsOpen = detailsOpen
        self.onToggleDetails = onToggleDetails
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            RoundIconButton(systemName: "slider.horizontal.3", size: 30, help: "Details",
                            action: onToggleDetails)
                .highlighted(detailsOpen ? palette.textPrimary.opacity(0.35) : nil)
                .accessibilityValue(detailsOpen ? "Open" : "Closed")
        }
        .padding(.horizontal, 4)
    }
}
