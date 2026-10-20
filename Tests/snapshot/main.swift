import AppKit
import SwiftUI

// Offline snapshots of the popover panel: renders a fixed set of states in light
// and dark appearance to build/snapshots/<name>-<light|dark>.png for visual review.
// No network, account, Keychain or device: the model only gets `loadPreview`.
// Run via Tests/snapshot.sh.

struct Scenario {
    let name: String
    var phase: DysonModel.Phase = .live
    var device: DysonDevice? = Scenario.device
    var state: [String: String] = Scenario.state
    var env: [String: String] = Scenario.env
    var showingDetails = false

    static let device = DysonDevice(serial: "TST-EU-AAA0001A", name: "Living room",
                                    model: "HP09", topicRoot: "527K")
    static let state = [
        "fpwr": "ON", "fnst": "FAN", "hmod": "HEAT", "hsta": "HEAT", "hmax": "2972",
        "fnsp": "0004", "auto": "OFF", "oson": "ON", "sltm": "OFF", "nmod": "OFF",
        "rhtm": "OFF", "hflr": "0065", "fdir": "ON", "ercd": "NONE",
    ]
    static let env = [
        "tact": "2961", "hact": "0045", "pm25": "0012", "pm10": "0015",
        "va10": "0034", "hchr": "0012", "noxl": "0003",
    ]
}

extension Dictionary where Key == String, Value == String {
    func with(_ changes: [String: String]) -> [String: String] {
        merging(changes) { _, new in new }
    }
}

let scenarios = [
    Scenario(name: "live-heat"),
    Scenario(name: "live-cool-auto",
             state: Scenario.state.with(["hmod": "OFF", "hsta": "OFF", "fnsp": "AUTO",
                                         "auto": "ON", "oson": "OFF", "sltm": "0030",
                                         "fdir": "OFF"])),  // back airflow
    Scenario(name: "off",
             state: Scenario.state.with(["fpwr": "OFF", "fnst": "OFF", "hsta": "OFF"]),
             env: Scenario.env.mapValues { _ in "OFF" }),
    Scenario(name: "offline", phase: .offline("The connection timed out.")),
    Scenario(name: "signed-out", phase: .signedOut, device: nil, state: [:], env: [:]),
    Scenario(name: "details", state: Scenario.state.with(["ercd": "12E1"]), showingDetails: true),
]

let appearances: [(name: String, appearance: NSAppearance.Name, scheme: ColorScheme)] = [
    ("light", .aqua, .light),
    ("dark", .darkAqua, .dark),
]

/// The real app activates before showing the popover; these report active / key
/// so controls draw in their active colors (accent-tinted switches, progress)
/// although the snapshot process never activates or takes focus.
final class SnapshotApplication: NSApplication {
    override var isActive: Bool { true }
}

final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

let scale: CGFloat = 2
let settleTime: TimeInterval = 0.6

func settle(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Renders the view hierarchy at `scale` regardless of the window's backing scale.
func render(_ view: NSView) -> NSBitmapImageRep? {
    let bounds = view.bounds
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int((bounds.width * scale).rounded(.up)),
        pixelsHigh: Int((bounds.height * scale).rounded(.up)),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = bounds.size
    view.cacheDisplay(in: bounds, to: rep)
    return rep
}

/// A blank or failed render comes out as a single flat color.
func distinctColors(_ rep: NSBitmapImageRep, atLeast limit: Int) -> Bool {
    var seen = Set<UInt32>()
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            var p = [Int](repeating: 0, count: 4)
            rep.getPixel(&p, atX: x, y: y)
            seen.insert(UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3]))
            if seen.count >= limit { return true }
        }
    }
    return false
}

@MainActor
func snapshot(_ scenario: Scenario, appearanceName: String, appearance: NSAppearance.Name,
              scheme: ColorScheme, defaults: UserDefaults, to dir: URL) -> URL? {
    let model = DysonModel(store: MemorySessionStore(), defaults: defaults)
    model.loadPreview(phase: scenario.phase, device: scenario.device,
                      state: scenario.state, env: scenario.env)

    let root = PopoverView(onSignIn: {}, initiallyShowingDetails: scenario.showingDetails)
        .environmentObject(model)
        .background(Palette.forScheme(scheme).background)
    let hosting = NSHostingView(rootView: root)
    hosting.frame.size = hosting.fittingSize

    let window = SnapshotWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000),
                                                    size: hosting.frame.size),
                                styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.backgroundColor = NSColor(Palette.forScheme(scheme).background)
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)  // key within this never-active app: takes no focus

    // Let layout settle (and the airflow animation advance), then refit in case
    // the content changed size after appearing.
    settle(settleTime / 2)
    let fitted = hosting.fittingSize
    if fitted != hosting.frame.size {
        window.setContentSize(fitted)
        hosting.frame.size = fitted
    }
    settle(settleTime / 2)
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()

    var rep: NSBitmapImageRep?
    window.appearance?.performAsCurrentDrawingAppearance {
        rep = render(hosting)
    }
    window.orderOut(nil)
    window.close()

    guard let rep = rep else {
        print("FAIL \(scenario.name)-\(appearanceName): could not allocate bitmap")
        return nil
    }
    guard distinctColors(rep, atLeast: 16) else {
        print("FAIL \(scenario.name)-\(appearanceName): rendered blank")
        return nil
    }
    let url = dir.appendingPathComponent("\(scenario.name)-\(appearanceName).png")
    do {
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("FAIL \(scenario.name)-\(appearanceName): PNG encoding")
            return nil
        }
        try png.write(to: url)
    } catch {
        print("FAIL \(scenario.name)-\(appearanceName): \(error.localizedDescription)")
        return nil
    }
    let size = hosting.frame.size
    print(url.path,
          "(\(Int(size.width))x\(Int(size.height)) pt, \(rep.pixelsWide)x\(rep.pixelsHigh) px)")
    return url
}

let app = SnapshotApplication.shared  // first access: makes NSApp the subclass
app.setActivationPolicy(.prohibited)

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/snapshots",
                 isDirectory: true)
do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
} catch {
    print("FAIL cannot create \(outDir.path): \(error.localizedDescription)")
    exit(1)
}

let suite = "dysonbar.snapshot.\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: suite) else {
    print("FAIL cannot create defaults suite")
    exit(1)
}

var failures = 0
for scenario in scenarios {
    for look in appearances {
        let url = MainActor.assumeIsolated {
            snapshot(scenario, appearanceName: look.name, appearance: look.appearance,
                     scheme: look.scheme, defaults: defaults, to: outDir)
        }
        if url == nil { failures += 1 }
    }
}

defaults.removePersistentDomain(forName: suite)

if failures > 0 {
    print("\(failures) snapshot(s) failed")
    exit(1)
}
print("\(scenarios.count * appearances.count) snapshots in \(outDir.path)")
