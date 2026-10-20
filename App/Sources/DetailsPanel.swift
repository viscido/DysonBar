import SwiftUI

/// Everything the main panel leaves out: full sensor readings, filter life,
/// secondary options and device info. Revealed by the footer's sliders button.
struct DetailsPanel: View {
    @EnvironmentObject var model: DysonModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            airQualitySection
            if let life = model.filterLife {
                filterSection(life)
            }
            optionsSection
            deviceSection
        }
    }

    // MARK: - air quality

    private var readings: [(label: String, value: Double?, spec: String)] {
        var list: [(label: String, value: Double?, spec: String)] = [
            ("PM2.5 µg/m³", model.pm25, "%.0f"),
            ("PM10 µg/m³", model.pm10, "%.0f"),
            ("VOC index", model.voc, "%.1f"),
            ("NO₂ index", model.nox, "%.1f"),
        ]
        if model.hasFormaldehydeSensor {
            list.append(("HCHO mg/m³", model.formaldehyde, "%.3f"))
        }
        list.append(("Temperature", model.roomTempC, "%.1f°C"))
        list.append(("Humidity", model.humidity, "%.0f%%"))
        return list
    }

    private var airQualitySection: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Air quality")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading),
                                         count: 3),
                          alignment: .leading, spacing: 10) {
                    ForEach(readings, id: \.label) { r in
                        reading(r.label, value: r.value.map { String(format: r.spec, $0) } ?? "—")
                    }
                }
                if readings.allSatisfy({ $0.value == nil }) {
                    caption("Sensors read only while the fan runs.")
                }
            }
        }
    }

    private func reading(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(palette.textPrimary)
        }
    }

    // MARK: - filter

    private func filterSection(_ life: Double) -> some View {
        let tint = life < 0.2 ? palette.warning : palette.good
        return PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Filter")
                HStack {
                    Text("HEPA filter")
                        .font(.system(size: 12))
                        .foregroundColor(palette.textPrimary)
                    Spacer()
                    Text("\(Int((life * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(life < 0.2 ? palette.warning : palette.textPrimary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.control)
                        Capsule().fill(tint).frame(width: max(4, geo.size.width * life))
                    }
                }
                .frame(height: 4)
                caption("Estimated by the purifier from hours of use. After replacing the filter, "
                        + "reset it on the device or in the MyDyson app.")
            }
        }
    }

    // MARK: - options

    private var optionsSection: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Options")
                optionRow("Night mode", isOn: model.nightMode) { _ in model.toggleNight() }
                optionRow("Continuous monitoring", isOn: model.continuous) { _ in model.toggleContinuous() }
                if model.hasFrontAirflowSetting {
                    optionRow("Front airflow", isOn: model.frontAirflow) { model.setFrontAirflow($0) }
                }
            }
            .disabled(!model.connected)
        }
    }

    private func optionRow(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: - device

    private var deviceSection: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Device")
                Text(model.deviceName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(palette.textPrimary)
                if let modelName = model.device?.model {
                    Text(modelName)
                        .font(.system(size: 11))
                        .foregroundColor(palette.textSecondary)
                }
                // `ercd` as reported by the device. Dyson does not document these codes and a
                // device can keep reporting an old one while MyDyson shows no alert: a quiet detail.
                if let code = model.errorCode {
                    Text("Device code \(code)")
                        .font(.system(size: 10))
                        .foregroundColor(palette.textSecondary)
                        .help("Code reported by the purifier (ercd). If the MyDyson app shows no alert, "
                              + "there is nothing to do; if the purifier misbehaves, check the MyDyson app.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(palette.textSecondary)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
