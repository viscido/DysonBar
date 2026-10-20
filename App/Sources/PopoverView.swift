import SwiftUI

/// The menu-bar panel: header, illustrated purifier, setpoint slider, control
/// tiles and a status footer that reveals `DetailsPanel`.
struct PopoverView: View {
    @EnvironmentObject var model: DysonModel
    let onSignIn: () -> Void

    @State private var showingDetails: Bool
    /// Slider value while dragging; nil once committed (the model then reflects it).
    @State private var draftTarget: Double?

    init(onSignIn: @escaping () -> Void, initiallyShowingDetails: Bool = false) {
        self.onSignIn = onSignIn
        _showingDetails = State(initialValue: initiallyShowingDetails)
    }

    var body: some View {
        PanelContent(onSignIn: onSignIn, showingDetails: $showingDetails, draftTarget: $draftTarget)
            .themed()
    }
}

/// Body of the panel, rendered inside `.themed()` so the palette matches the appearance.
private struct PanelContent: View {
    @EnvironmentObject var model: DysonModel
    @Environment(\.palette) private var palette
    let onSignIn: () -> Void
    @Binding var showingDetails: Bool
    @Binding var draftTarget: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.phase == .signedOut {
                PurifierHero(isOn: false, style: .cool, fanLevel: nil, oscillating: false)
                    .opacity(0.45)
                signInCard
            } else {
                if !showingDetails {
                    PurifierHero(isOn: model.isOn && model.connected,
                                 style: model.heatModeOn ? .heat : .cool,
                                 fanLevel: model.fanSpeedNumber,
                                 oscillating: model.rotation,
                     frontAirflow: model.frontAirflow)
                        .transition(.opacity)
                    if showsAirQuality {
                        AirQualityStrip(items: airQualityItems)
                            .transition(.opacity)
                    }
                }
                Group {
                    setpointBlock
                    tiles
                }
                .disabled(!model.connected)
                if showingDetails {
                    DetailsPanel()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                footer
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(palette.background.ignoresSafeArea())
    }

    private var accent: Color { model.heatModeOn ? palette.heat : palette.cool }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.deviceName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(palette.textSecondary)
                    Text("Room")
                        .font(.system(size: 13))
                        .foregroundColor(palette.textSecondary)
                    Text(model.roomTempC.map { String(format: "%.0f°C", $0) } ?? "—")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(palette.textPrimary)
                        .monospacedDigit()
                }
            }
            Spacer()
            if model.phase != .signedOut {
                PowerButton(isOn: model.isOn, tint: accent, action: { model.togglePower() })
                    .disabled(!model.connected)
                    .help(model.isOn ? "Turn off" : "Turn on")
            }
        }
    }

    // MARK: - air quality

    /// Sensors have no values while connecting; offline keeps the last readings.
    private var showsAirQuality: Bool {
        switch model.phase {
        case .live, .offline: return true
        case .connecting, .signedOut: return false
        }
    }

    private var airQualityItems: [AirQualityItem] {
        var items = [
            AirQualityItem(id: "pm25", label: "PM2.5", value: format(model.pm25, "%.0f"),
                           level: model.pm25.map { level($0, good: 12, fair: 35) }),
            AirQualityItem(id: "voc", label: "VOC", value: format(model.voc, "%.1f"),
                           level: model.voc.map { level($0, good: 3, fair: 6) }),
        ]
        if model.hasFormaldehydeSensor {
            items.append(AirQualityItem(id: "hcho", label: "HCHO", value: format(model.formaldehyde, "%.3f"),
                                        level: model.formaldehyde.map { level($0, good: 0.05, fair: 0.1) }))
        }
        items.append(AirQualityItem(id: "humidity", label: "Humidity", value: format(model.humidity, "%.0f%%"),
                                    level: model.humidity.map(humidityLevel)))
        return items
    }

    private func level(_ value: Double, good: Double, fair: Double) -> AirQualityLevel {
        value <= good ? .good : value <= fair ? .fair : .poor
    }

    private func humidityLevel(_ value: Double) -> AirQualityLevel {
        if (40...60).contains(value) { return .good }
        if (30...70).contains(value) { return .fair }
        return .poor
    }

    // MARK: - setpoint

    @ViewBuilder
    private var setpointBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    if model.hasHeater {
                        bigNumber(heatTargetText, unit: "°C")
                        caption(model.heatModeOn ? (model.isHeating ? "Heating" : "Heat target")
                                                 : "Heating off — drag to heat")
                    } else {
                        bigNumber(fanText, unit: "Fan")
                        caption(model.autoMode ? "Auto fan speed" : "Fan speed")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Fixed width: the number changes width ("25" → "25.5") and must
                // not push the chip around.
                ToggleChip(title: "Auto", systemImage: "wand.and.stars", isOn: model.autoMode,
                           onToggle: { _ in model.toggleAuto() })
                    .frame(width: 164)
            }
            if model.hasHeater {
                TemperatureSlider(
                    value: Binding(get: { draftTarget ?? model.heatTargetC ?? 20 },
                                   set: { draftTarget = $0 }),
                    range: DysonModel.heatRange, step: 0.5, tint: accent,
                    onCommit: { model.setHeatTarget($0); draftTarget = nil })
            } else {
                TemperatureSlider(
                    value: Binding(get: { draftTarget ?? Double(model.fanSpeedNumber ?? 5) },
                                   set: { draftTarget = $0 }),
                    range: 1...10, step: 1, tint: palette.cool,
                    onCommit: { model.setFanSpeed(Int($0)); draftTarget = nil })
            }
        }
    }

    private var heatTargetText: String {
        guard let v = draftTarget ?? model.heatTargetC else { return "—" }
        return String(format: v == v.rounded() ? "%.0f" : "%.1f", v)
    }

    private var fanText: String {
        if let v = draftTarget { return String(format: "%.0f", v) }
        return model.fanSpeedText
    }

    private func bigNumber(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .foregroundColor(palette.textPrimary)
                .contentTransition(.numericText())
            Text(unit)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundColor(palette.textSecondary)
        }
        .lineLimit(1)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(palette.textSecondary)
    }

    // MARK: - tiles

    private var tiles: some View {
        HStack(spacing: 8) {
            modeTile
            ControlTile(systemImage: "fanblades", title: "Fan speed", value: model.fanSpeedText,
                        accessory: .menu(options: Self.fanOptions,
                                         selectedID: model.fanSpeedNumber.map(String.init) ?? "auto",
                                         onSelect: { id in model.setFanSpeed(Int(id)) }))
            ControlTile(systemImage: "moon", title: "Sleep", value: model.sleepTimerText,
                        accessory: .menu(options: Self.sleepOptions,
                                         selectedID: String(model.sleepMinutes ?? 0),
                                         onSelect: { id in model.setSleep(minutes: Int(id) ?? 0) }),
                        isActive: model.sleepMinutes != nil)
            ControlTile(systemImage: "arrow.left.and.right", title: "Rotation",
                        value: model.rotation ? "On" : "Off",
                        accessory: .dot(active: model.rotation),
                        isActive: model.rotation,
                        onTap: { model.toggleRotation() })
        }
    }

    @ViewBuilder
    private var modeTile: some View {
        if model.hasHeater {
            ControlTile(systemImage: model.heatModeOn ? "flame" : "snowflake", title: "Mode",
                        value: model.heatModeOn ? "Heat" : "Cool",
                        accessory: .menu(options: [TileOption(id: "heat", title: "Heat"),
                                                   TileOption(id: "cool", title: "Cool")],
                                         selectedID: model.heatModeOn ? "heat" : "cool",
                                         onSelect: { id in model.setHeatMode(id == "heat") }),
                        isActive: model.heatModeOn)
        } else {
            ControlTile(systemImage: "fanblades", title: "Mode", value: "Fan", accessory: .none)
        }
    }

    private static let fanOptions: [TileOption] =
        [TileOption(id: "auto", title: "Auto")] + (1...10).map { TileOption(id: "\($0)", title: "\($0)") }

    private static let sleepOptions: [TileOption] = DysonModel.sleepPresets.map { m in
        let title = m == 0 ? "Off" : m >= 60 ? "\(m / 60)h" : "\(m)m"
        return TileOption(id: "\(m)", title: title)
    }

    // MARK: - footer

    @ViewBuilder
    private var footer: some View {
        let toggle = {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showingDetails.toggle() }
        }
        switch model.phase {
        case .live:
            StatusFooter(text: "Connected", systemImage: "checkmark.shield", tint: palette.good,
                         detailsOpen: showingDetails, onToggleDetails: toggle)
        case .connecting, .signedOut:
            StatusFooter(text: "Connecting…", systemImage: "arrow.triangle.2.circlepath",
                         tint: palette.textSecondary, detailsOpen: showingDetails, onToggleDetails: toggle)
        case .offline(let reason):
            StatusFooter(text: "Offline — retrying", systemImage: "exclamationmark.triangle",
                         tint: palette.warning, detailsOpen: showingDetails, onToggleDetails: toggle)
                .help(reason)
        }
    }

    // MARK: - signed out

    private var signInCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sign in with your Dyson account to control your purifier from the menu bar.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Sign in…", action: onSignIn)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Sensors read "OFF" while the fan is idle; show a neutral dash.
    private func format(_ value: Double?, _ spec: String) -> String {
        guard let v = value else { return "—" }
        return String(format: spec, v)
    }
}
