import SwiftUI

/// Tint of the animated airflow: warm when heating, cool when only purifying.
enum AirflowStyle { case heat, cool }

/// Stylized tower purifier with animated airflow. Height 150, flexible width.
///
/// A generic tower (cylindrical grille base, hollow loop on top) stands in
/// the center, seen front-on from slightly above. Front airflow leaves the
/// loop's opening toward the viewer, with wavefronts and streaks drawn in
/// front of the tower; back airflow leaves the back of the loop and recedes
/// behind it as a soft haze. While oscillating the tower turns on its base
/// and every streak travels along the direction the loop faced when it was
/// blown, so the plume sweeps with it. Speed and density follow the fan
/// level; the airflow fades out when the device turns off.
struct PurifierHero: View {
    let isOn: Bool
    let style: AirflowStyle
    let fanLevel: Int?
    let oscillating: Bool
    let frontAirflow: Bool

    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var visibility: Double
    @State private var sway: Double
    @State private var level: Double
    @State private var front: Double
    @State private var running: Bool
    @State private var clock: FlowClock

    init(isOn: Bool, style: AirflowStyle, fanLevel: Int?, oscillating: Bool, frontAirflow: Bool = true) {
        self.isOn = isOn
        self.style = style
        self.fanLevel = fanLevel
        self.oscillating = oscillating
        self.frontAirflow = frontAirflow
        let level = Self.level(fanLevel)
        _visibility = State(initialValue: isOn ? 1 : 0)
        _sway = State(initialValue: isOn && oscillating ? 1 : 0)
        _level = State(initialValue: level)
        _front = State(initialValue: frontAirflow ? 1 : 0)
        _running = State(initialValue: isOn)
        _clock = State(initialValue: FlowClock(speed: Flow.speed(level)))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running || reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            HeroScene(time: t,
                      phase: reduceMotion ? 0.37 : clock.phase(at: t),
                      visibility: visibility * (reduceMotion ? 0.55 : 1),
                      sway: reduceMotion ? 0 : sway,
                      level: level,
                      front: front,
                      palette: palette,
                      accent: style == .heat ? palette.heat : palette.cool,
                      isOn: isOn,
                      isDark: scheme == .dark)
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .onChange(of: isOn) { _, on in
            if on { running = true }
            withAnimation(.easeOut(duration: 0.6)) {
                visibility = on ? 1 : 0
            } completion: {
                if visibility == 0 { running = false }
            }
            withAnimation(.easeInOut(duration: 1.2)) { sway = on && oscillating ? 1 : 0 }
        }
        .onChange(of: oscillating) { _, osc in
            withAnimation(.easeInOut(duration: 1.2)) { sway = isOn && osc ? 1 : 0 }
        }
        .onChange(of: frontAirflow) { _, isFront in
            withAnimation(.easeInOut(duration: 0.6)) { front = isFront ? 1 : 0 }
        }
        .onChange(of: fanLevel) { _, newLevel in
            let target = Self.level(newLevel)
            clock = clock.retimed(speed: Flow.speed(target), at: Date().timeIntervalSinceReferenceDate)
            withAnimation(.easeInOut(duration: 0.8)) { level = target }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard isOn else { return "Purifier off" }
        let mode = style == .heat ? "heating" : "cooling"
        let fan = fanLevel.map { "fan \($0)" } ?? "fan auto"
        return "Purifier on, \(mode), \(fan)" + (oscillating ? ", rotating" : "")
            + (frontAirflow ? ", front airflow" : ", back airflow")
    }

    private static func level(_ fanLevel: Int?) -> Double {
        Double(min(max(fanLevel ?? 5, 1), 10))
    }
}

/// Motion constants shared by the tower and the airflow.
private enum Flow {
    /// Streak lifetimes per second.
    static func speed(_ level: Double) -> Double { 0.12 + 0.05 * (level - 1) }

    /// Tower yaw in radians: ±40° over an 8 s period, scaled by `sway` (0…1).
    /// Positive turns the loop's opening to the viewer's right.
    static func yaw(at t: Double, sway: Double) -> Double {
        sway * 40 * .pi / 180 * sin(2 * .pi * t / 8)
    }
}

/// Continuous flow phase that survives speed changes without streaks jumping.
private struct FlowClock {
    var anchorTime: Double = 0
    var anchorPhase: Double = 0
    var speed: Double

    func phase(at t: Double) -> Double { anchorPhase + (t - anchorTime) * speed }

    func retimed(speed: Double, at t: Double) -> FlowClock {
        FlowClock(anchorTime: t, anchorPhase: phase(at: t), speed: speed)
    }
}

/// One frame of the hero. Fade, sway, density and airflow direction animate
/// smoothly, so the tower also eases back to rest while the timeline is paused.
private struct HeroScene: View, Animatable {
    let time: Double
    let phase: Double
    var visibility: Double
    var sway: Double
    var level: Double
    var front: Double
    let palette: Palette
    let accent: Color
    let isOn: Bool
    let isDark: Bool

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(visibility, sway), AnimatablePair(level, front)) }
        set {
            visibility = newValue.first.first
            sway = newValue.first.second
            level = newValue.second.first
            front = newValue.second.second
        }
    }

    var body: some View {
        let air = AirField(time: time, phase: phase, sway: sway, level: level,
                           color: accent, gain: (isDark ? 1.0 : 1.35) * visibility)
        ZStack {
            BackAirLayer(air: air, amount: 1 - front)
            // equatable: the tower redraws only when its yaw actually changes
            TowerLayer(palette: palette, yaw: Flow.yaw(at: time, sway: sway),
                       light: isOn ? accent : nil, isDark: isDark)
                .equatable()
            FrontAirLayer(air: air, amount: front)
        }
    }
}

/// Shared geometry of the tower, in the 150 pt tall hero.
private struct HeroLayout {
    let cx: CGFloat
    let loopOuter: CGRect
    let loopInner: CGRect
    let capY: CGFloat        // center of the base's top ellipse
    let bottomY: CGFloat     // center of the base's bottom ellipse
    let radius: CGFloat      // base half width
    let ry: CGFloat          // ellipse half height (view from slightly above)
    let shadowY: CGFloat

    init(size: CGSize) {
        let top = (size.height - 150) / 2
        cx = (size.width / 2).rounded()
        radius = 20
        ry = 4.6
        capY = top + 90
        bottomY = top + 135
        shadowY = top + 140
        loopOuter = CGRect(x: cx - 16.5, y: top + 7, width: 33, height: 95)
        loopInner = CGRect(x: cx - 9.5, y: top + 14.5, width: 19, height: 67)
    }

    /// Center of the loop's opening: the origin of the airflow.
    var aperture: CGPoint { CGPoint(x: cx, y: loopInner.midY) }
}

/// The tower: contact shadow, cylinder base with grille, loop. The yaw is
/// faked in 2D: the loop foreshortens and shows its thickness on the side
/// it turns away from, the grille scrolls around the cylinder and the
/// status light travels across the base front.
private struct TowerLayer: View, Equatable {
    let palette: Palette
    let yaw: Double
    let light: Color?
    let isDark: Bool

    static func == (a: TowerLayer, b: TowerLayer) -> Bool {
        a.yaw == b.yaw && a.light == b.light && a.isDark == b.isDark
    }

    var body: some View {
        Canvas { ctx, size in
            let l = HeroLayout(size: size)
            let body = palette.deviceBody, shade = palette.deviceShade, detail = palette.deviceDetail
            let edge = detail.opacity(isDark ? 0.35 : 0.28)

            // contact shadow
            let shadowRect = CGRect(x: l.cx - 34, y: l.shadowY - 6, width: 68, height: 12)
            ctx.fill(Path(ellipseIn: shadowRect), with: .radialGradient(
                Gradient(colors: [.black.opacity(isDark ? 0.55 : 0.16), .black.opacity(0)]),
                center: CGPoint(x: shadowRect.midX, y: shadowRect.midY), startRadius: 0, endRadius: 34))

            // base cylinder (round, so its outline and lighting stay still)
            let left = l.cx - l.radius, right = l.cx + l.radius
            var cylinder = Path(CGRect(x: left, y: l.capY, width: l.radius * 2, height: l.bottomY - l.capY))
            cylinder.addEllipse(in: CGRect(x: left, y: l.bottomY - l.ry, width: l.radius * 2, height: l.ry * 2))
            let roundShading = Gradient(stops: [
                .init(color: shade, location: 0),
                .init(color: body, location: 0.28),
                .init(color: body, location: 0.42),
                .init(color: shade, location: 0.86),
                .init(color: detail.opacity(0.9), location: 1.2),
            ])
            ctx.fill(cylinder, with: .linearGradient(roundShading,
                startPoint: CGPoint(x: left, y: 0), endPoint: CGPoint(x: right, y: 0)))

            // grille: dot rows wrapped around the cylinder, scrolling with the yaw
            let step = Double.pi / 2 / 8.6
            var row = 0
            var y = l.capY + 13
            while y < l.bottomY - 6 {
                let offset = (row % 2 == 0 ? 0 : 0.5) * step + yaw
                let first = ((-1.5 - offset) / step).rounded(.up)
                for k in stride(from: first, through: (1.5 - offset) / step, by: 1) {
                    let a = k * step + offset
                    let front = cos(a)
                    let x = l.cx + l.radius * CGFloat(sin(a))
                    let r = 0.45 + 0.35 * CGFloat(front)
                    let lit = (0.25 + 0.4 * front * (a < 0.35 ? 1 : 0.8)) * min(1, front * 6)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y + l.ry * CGFloat(front) - r, width: r * 2, height: r * 2)),
                             with: .color(detail.opacity(lit)))
                }
                y += 3.3
                row += 1
            }
            // seam between grille band and plain foot
            var seam = Path()
            seam.addArc(center: .zero, radius: 1, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
            ctx.stroke(seam.applying(CGAffineTransform(scaleX: l.radius, y: l.ry)
                .concatenating(CGAffineTransform(translationX: l.cx, y: l.bottomY - 4))),
                with: .color(detail.opacity(0.22)), lineWidth: 0.6)

            // top cap, lit from above
            let cap = Path(ellipseIn: CGRect(x: left, y: l.capY - l.ry, width: l.radius * 2, height: l.ry * 2))
            ctx.fill(cap, with: .linearGradient(Gradient(colors: [body, shade]),
                startPoint: CGPoint(x: left, y: l.capY - l.ry), endPoint: CGPoint(x: right, y: l.capY + l.ry)))
            ctx.stroke(cap, with: .color(edge), lineWidth: 0.5)
            ctx.stroke(cylinder, with: .color(edge.opacity(isDark ? 0.0 : 0.7)), lineWidth: 0.5)

            // status light: on the front of the body, dimming as it turns away
            let lightFront = cos(yaw)
            let lightCenter = CGPoint(x: l.cx + l.radius * 0.94 * CGFloat(sin(yaw)),
                                      y: l.capY + l.ry * CGFloat(lightFront) + 3.6)
            let lightScale = 0.4 + 0.6 * lightFront
            let dotR = 1.1 * CGFloat(0.55 + 0.45 * lightFront)
            if let light {
                ctx.fill(Path(ellipseIn: CGRect(x: lightCenter.x - 4, y: lightCenter.y - 4, width: 8, height: 8)),
                         with: .radialGradient(Gradient(colors: [light.opacity(0.55 * lightScale), light.opacity(0)]),
                                               center: lightCenter, startRadius: 0, endRadius: 4))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: lightCenter.x - dotR, y: lightCenter.y - dotR, width: dotR * 2, height: dotR * 2)),
                     with: .color((light ?? detail.opacity(0.5)).opacity(lightScale)))

            // loop, standing on the cap: foreshortened face plus its thickness.
            // The thickness runs back along -facing, seen from slightly above.
            let scale = CGFloat(max(cos(yaw), 0.55))
            let thickness = 8.0
            let faceX = l.cx + CGFloat(thickness / 2 * sin(yaw))
            let backShift = CGSize(width: -thickness * sin(yaw), height: -thickness * cos(yaw) * Camera.rise)
            func capsule(_ rect: CGRect) -> Path {
                let w = rect.width * scale
                return Path(roundedRect: CGRect(x: faceX - w / 2, y: rect.minY, width: w, height: rect.height),
                            cornerSize: CGSize(width: w / 2, height: rect.width / 2))
            }
            let outer = capsule(l.loopOuter), inner = capsule(l.loopInner)
            let face = outer.boundingRect
            ctx.drawLayer { loop in
                loop.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: l.capY)))
                var ring = outer
                ring.addPath(inner)
                let back = ring.applying(CGAffineTransform(translationX: backShift.width, y: backShift.height))
                loop.fill(back, with: .linearGradient(Gradient(colors: [shade, detail.opacity(0.85)]),
                    startPoint: CGPoint(x: face.minX - 8, y: 0), endPoint: CGPoint(x: face.maxX + 8, y: 0)),
                    style: FillStyle(eoFill: true))

                let sheen = 0.26 - 0.14 * sin(yaw)
                let faceShading = Gradient(stops: [
                    .init(color: shade, location: 0),
                    .init(color: body, location: sheen),
                    .init(color: body, location: sheen + 0.3),
                    .init(color: shade, location: 1.05),
                ])
                loop.fill(ring, with: .linearGradient(faceShading,
                    startPoint: CGPoint(x: face.minX, y: 0), endPoint: CGPoint(x: face.maxX, y: 0)),
                    style: FillStyle(eoFill: true))
                loop.fill(ring, with: .linearGradient(Gradient(colors: [shade.opacity(0), shade.opacity(0.45)]),
                    startPoint: CGPoint(x: 0, y: face.minY + 30), endPoint: CGPoint(x: 0, y: l.capY)),
                    style: FillStyle(eoFill: true))
                // airflow slit along the inner rim and a soft highlight
                loop.stroke(inner, with: .color(detail.opacity(0.3)), lineWidth: 0.6)
                let rim = face.insetBy(dx: 2.6 * scale, dy: 2.6)
                let highlight = Path(roundedRect: rim, cornerSize: CGSize(width: rim.width / 2, height: l.loopOuter.width / 2 - 2.6))
                let glint = face.minX + face.width * CGFloat(sheen)
                loop.stroke(highlight, with: .linearGradient(
                    Gradient(colors: [.white.opacity(isDark ? 0.5 : 0.9), .white.opacity(0)]),
                    startPoint: CGPoint(x: glint - 6, y: face.minY),
                    endPoint: CGPoint(x: glint + 12, y: face.midY)), lineWidth: 1)
                loop.stroke(outer, with: .color(edge), lineWidth: 0.5)
            }
            // collar where the loop meets the base
            var collar = Path()
            collar.move(to: CGPoint(x: min(face.minX, face.minX + backShift.width), y: l.capY))
            collar.addLine(to: CGPoint(x: max(face.maxX, face.maxX + backShift.width), y: l.capY))
            ctx.stroke(collar, with: .color(detail.opacity(0.35)), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

/// Mild perspective from a slightly raised eye. Points are in loop space
/// (x right, y down, z toward the viewer), centered on the loop's opening.
private struct Camera {
    static let focal = 300.0
    static let rise = 0.25   // nearer points sit lower on screen

    let origin: CGPoint

    /// Screen position and scale of a point in loop space.
    func project(_ p: Vec3) -> (point: CGPoint, scale: Double) {
        let s = Self.focal / (Self.focal - min(p.z, 170))
        return (CGPoint(x: Double(origin.x) + p.x * s, y: Double(origin.y) + (p.y + p.z * Self.rise) * s), s)
    }
}

private struct Vec3 {
    var x, y, z: Double
    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func * (a: Vec3, k: Double) -> Vec3 { Vec3(x: a.x * k, y: a.y * k, z: a.z * k) }
}

/// The particle field shared by both airflow layers. Each streak follows a
/// straight line along the loop's facing at the moment it was blown, so the
/// whole plume sweeps with the tower and never jumps.
private struct AirField {
    let time: Double
    let phase: Double
    let sway: Double
    let level: Double
    let color: Color
    let gain: Double

    private struct Streak {
        let head: CGPoint, tail: CGPoint
        let scale: Double, alpha: Double, seed: Double
    }

    /// Streak `i` of the front (out of the opening) or back (out of the back) flow.
    private func streak(_ i: Int, front: Bool, layout l: HeroLayout, camera: Camera) -> Streak? {
        let pace = 0.75 + 0.5 * hash(i, 2)
        let u = fract(hash(i, 3) + phase * pace)
        let fade = front
            ? smooth(0, 0.06, u) * (1 - smooth(0.45, 0.92, u))
            : smooth(0, 0.08, u) * (1 - smooth(0.4, 0.95, u))
        guard fade > 0.01 else { return nil }

        let lag = min(1 / (Flow.speed(level) * pace), 0.15)
        let yaw = Flow.yaw(at: time - u * lag, sway: sway)
        let facing = Vec3(x: sin(yaw), y: 0, z: cos(yaw))
        let side = Vec3(x: cos(yaw), y: 0, z: -sin(yaw))
        let up = Vec3(x: 0, y: 1, z: 0)

        // leave from the inner rim, then fan out in a cone
        let rimAngle = hash(i, 1) * 2 * .pi
        let rim = side * (cos(rimAngle) * Double(l.loopInner.width) * 0.42)
            + up * (sin(rimAngle) * Double(l.loopInner.height) * 0.44)
        let spreadX = hash(i, 4) * 2 - 1, spreadY = hash(i, 5) * 2 - 1
        let direction = front
            ? facing + side * (spreadX * 0.6) + up * (spreadY * 0.22 - 0.12)
            : facing * -1 + side * (spreadX * 0.9) + up * (spreadY * 0.3 + 0.1)
        let start = rim + facing * (front ? 4 : -4)
        let travel = front ? 150.0 : 130.0
        let length = (front ? 22 : 14) + 14 * hash(i, 6) + level * 1.5
        let swirl = hash(i, 7) * 2 * .pi
        func at(_ s: Double) -> Vec3 {
            let wobble = sin(s * 0.07 + time * (0.7 + 0.5 * hash(i, 8)) + swirl) * (1 + s * 0.03)
            return start + direction * s + up * wobble
        }
        let s = u * travel
        let head = camera.project(at(s)), tail = camera.project(at(max(0, s - length)))
        return Streak(head: head.point, tail: tail.point, scale: head.scale, alpha: fade * gain, seed: hash(i, 9))
    }

    /// Air pushed out of the opening toward the viewer: wavefronts, streaks
    /// and particles that grow and spread as they come closer.
    func drawFront(in ctx: inout GraphicsContext, size: CGSize, amount: Double) {
        let l = HeroLayout(size: size)
        let camera = Camera(origin: l.aperture)
        let gain = amount
        let yaw = Flow.yaw(at: time, sway: sway)
        let facing = Vec3(x: sin(yaw), y: 0, z: cos(yaw))

        // glow in the opening and a soft cone of air ahead of it
        let mouth = l.aperture
        glow(&ctx, at: mouth, radius: 34, alpha: 0.22 * gain)
        let ahead = camera.project(facing * 70)
        glow(&ctx, at: ahead.point, radius: 80, alpha: 0.10 * gain)

        // wavefronts: copies of the opening that grow and fade as they travel out
        for k in 0..<3 {
            let age = fract(phase * 1.6 + Double(k) / 3)
            let ringYaw = Flow.yaw(at: time - age * 0.15, sway: sway)
            let ringFacing = Vec3(x: sin(ringYaw), y: 0, z: cos(ringYaw))
            let p = camera.project(ringFacing * (age * 60 + 4))
            let grow = (1 + age * 1.3) * p.scale
            let w = Double(l.loopInner.width) * max(cos(ringYaw), 0.55) * grow
            let h = Double(l.loopInner.height) * grow
            let rect = CGRect(x: p.point.x - w / 2, y: p.point.y - h / 2, width: w, height: h)
            let ring = Path(roundedRect: rect, cornerSize: CGSize(width: w / 2, height: Double(l.loopInner.width) * grow / 2))
            let alpha = smooth(0, 0.12, age) * pow(1 - age, 1.4) * 0.4 * gain * self.gain
            ctx.stroke(ring, with: .color(color.opacity(alpha)), lineWidth: 1.2 + 2.4 * age)
        }

        // streaks
        let count = 14 + level * 3.5
        for i in 0..<Int(count.rounded(.up)) {
            guard let s = streak(i, front: true, layout: l, camera: camera) else { continue }
            let a = s.alpha * min(1, count - Double(i)) * gain
            let shading = { (peak: Double) in
                GraphicsContext.Shading.linearGradient(Gradient(colors: [color.opacity(0), color.opacity(peak)]),
                                                       startPoint: s.tail, endPoint: s.head)
            }
            var path = Path()
            path.move(to: s.tail)
            path.addLine(to: s.head)
            ctx.stroke(path, with: shading(0.16 * a),
                       style: StrokeStyle(lineWidth: (4 + 3 * s.seed) * s.scale, lineCap: .round))
            ctx.stroke(path, with: shading(0.6 * a),
                       style: StrokeStyle(lineWidth: (0.7 + 0.7 * s.seed) * s.scale, lineCap: .round))
        }

        // particles
        let specks = 4 + level * 2
        for i in 0..<Int(specks.rounded(.up)) {
            guard let s = streak(i + 100, front: true, layout: l, camera: camera) else { continue }
            let a = s.alpha * min(1, specks - Double(i)) * gain * 0.7
            let r = (0.5 + 0.7 * s.seed) * s.scale
            ctx.fill(Path(ellipseIn: CGRect(x: s.head.x - r, y: s.head.y - r, width: r * 2, height: r * 2)),
                     with: .color(color.opacity(a)))
        }
    }

    /// Air pushed out of the back of the loop: it recedes, shrinks, rises
    /// a little and diffuses into soft puffs behind the tower.
    func drawBack(in ctx: inout GraphicsContext, size: CGSize, amount: Double) {
        let l = HeroLayout(size: size)
        let camera = Camera(origin: l.aperture)
        let gain = amount
        let yaw = Flow.yaw(at: time, sway: sway)
        let behind = camera.project(Vec3(x: -sin(yaw), y: 0.1, z: -cos(yaw)) * 70)
        glow(&ctx, at: behind.point, radius: 75, alpha: 0.14 * gain)

        let count = 10 + level * 3
        for i in 0..<Int(count.rounded(.up)) {
            guard let s = streak(i, front: false, layout: l, camera: camera) else { continue }
            let a = s.alpha * min(1, count - Double(i)) * gain
            // a puff that swells and thins out as the air diffuses
            let r = (5 + 9 * s.seed) * (1.6 - s.scale) * 1.6
            ctx.fill(Path(ellipseIn: CGRect(x: s.head.x - r, y: s.head.y - r, width: r * 2, height: r * 2)),
                     with: .radialGradient(Gradient(colors: [color.opacity(0.16 * a), color.opacity(0)]),
                                           center: s.head, startRadius: 0, endRadius: r))
            var path = Path()
            path.move(to: s.tail)
            path.addLine(to: s.head)
            ctx.stroke(path, with: .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(0.55 * a)]),
                                                   startPoint: s.tail, endPoint: s.head),
                       style: StrokeStyle(lineWidth: (0.7 + 0.8 * s.seed) * s.scale, lineCap: .round))
        }
    }

    private func glow(_ ctx: inout GraphicsContext, at center: CGPoint, radius: Double, alpha: Double) {
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                 with: .radialGradient(Gradient(colors: [color.opacity(alpha * gain), color.opacity(0)]),
                                       center: center, startRadius: 0, endRadius: radius))
    }

    private func hash(_ i: Int, _ salt: Int) -> Double {
        fract(sin(Double(i) * 12.9898 + Double(salt) * 78.233) * 43758.5453)
    }

    private func fract(_ x: Double) -> Double { x - x.rounded(.down) }

    private func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Front airflow, drawn over the tower. Carries the hero's only blur.
private struct FrontAirLayer: View {
    let air: AirField
    let amount: Double

    var body: some View {
        Canvas { ctx, size in
            guard amount * air.gain > 0.005 else { return }
            air.drawFront(in: &ctx, size: size, amount: amount)
        }
        .blur(radius: 1.5)
        .allowsHitTesting(false)
    }
}

/// Back airflow, drawn under the tower so the body occludes it.
/// Soft by construction (radial puffs), so it needs no blur.
private struct BackAirLayer: View {
    let air: AirField
    let amount: Double

    var body: some View {
        Canvas { ctx, size in
            guard amount * air.gain > 0.005 else { return }
            air.drawBack(in: &ctx, size: size, amount: amount)
        }
        .allowsHitTesting(false)
    }
}
