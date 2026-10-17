import SwiftUI

/// A polar map of the radio field. The phone sits at the center; each emitter sits at a
/// fixed bearing (from its hash) and a radius set by signal strength — strong = close.
/// Voiced emitters glow in the hue of their note, ripple when they sing, and shiver with jitter.
struct RadarView: View {
    let sources: [RadioSource]
    let air: Double
    let playing: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                draw(ctx, size: size, t: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func circle(_ p: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // Drawing lives in its own method with explicit types: as one big closure, the mix of
    // CGFloat and Double arithmetic was too slow for the compiler to type-check.
    private func draw(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let up: Double = ProcessInfo.processInfo.systemUptime
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R: Double = Double(min(size.width, size.height) / 2 - 10)

        // Range rings
        for i in 1...4 {
            let r = CGFloat(R * Double(i) / 4)
            ctx.stroke(circle(c, r), with: .color(.white.opacity(0.06)), lineWidth: 1)
        }

        // Slow sweep
        let sweep: Double = (t * 0.35).truncatingRemainder(dividingBy: 2 * .pi)
        var beam = Path()
        beam.move(to: c)
        beam.addArc(center: c, radius: CGFloat(R), startAngle: .radians(sweep - 0.5),
                    endAngle: .radians(sweep), clockwise: false)
        beam.closeSubpath()
        ctx.fill(beam, with: .color(.cyan.opacity(playing ? 0.05 : 0.025)))

        // Air haze around the listener
        let haze = CGFloat(R * (0.10 + 0.25 * air))
        let hazeTop: Double = 0.10 + 0.25 * air
        ctx.fill(circle(c, haze), with: .radialGradient(
            Gradient(colors: [.white.opacity(hazeTop), .clear]),
            center: c, startRadius: 0, endRadius: haze))

        for s in sources { drawSource(ctx, s, center: c, R: R, t: t, up: up) }

        // Listener
        ctx.fill(circle(c, 4), with: .color(.white))
    }

    private func drawSource(_ ctx: GraphicsContext, _ s: RadioSource, center c: CGPoint,
                            R: Double, t: Double, up: Double) {
        let angle: Double = Double(s.seed % 3600) / 3600 * 2 * .pi
        let jit: Double = s.jitterNorm
        let phase: Double = Double(s.seed % 100)
        let wobble: Double = jit * 7 * sin(t * (1.5 + jit * 9) + phase)
        let r: Double = R * (0.10 + 0.88 * (1 - s.level)) + wobble
        let p = CGPoint(x: c.x + CGFloat(cos(angle) * r), y: c.y + CGFloat(sin(angle) * r))
        let dot: Double = 2.5 + s.level * 9

        guard s.voice != nil else {
            let o: Double = 0.18 + 0.4 * s.level
            ctx.fill(circle(p, CGFloat(dot * 0.7)), with: .color(.white.opacity(o)))
            return
        }
        let hue: Double = Double(s.midi % 12) / 12
        let col = Color(hue: hue, saturation: 0.65, brightness: 1)
        var tether = Path()
        tether.move(to: c)
        tether.addLine(to: p)
        let tetherOpacity: Double = 0.10 + 0.25 * s.level
        ctx.stroke(tether, with: .color(col.opacity(tetherOpacity)), lineWidth: 1)
        let shiver: Double = 0.5 + 0.5 * sin(t * 6 + Double(s.seed % 50))
        let glow = CGFloat(dot * (3 + 1.5 * jit * shiver))
        ctx.fill(circle(p, glow), with: .radialGradient(
            Gradient(colors: [col.opacity(0.45), .clear]),
            center: p, startRadius: 0, endRadius: glow))
        ctx.fill(circle(p, CGFloat(dot)), with: .color(col))
        // Ripple outward each time this device's loop sings a note
        let age: Double = up - s.lastNote
        if age >= 0 && age < 5 {
            let rr = CGFloat(dot + age * 16)
            let fade: Double = 0.55 * (1 - age / 5)
            ctx.stroke(circle(p, rr), with: .color(col.opacity(fade)), lineWidth: 1.2)
        }
    }
}
