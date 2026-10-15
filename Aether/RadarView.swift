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
                let t = timeline.date.timeIntervalSinceReferenceDate
                let up = ProcessInfo.processInfo.systemUptime
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = min(size.width, size.height) / 2 - 10

                func circle(_ p: CGPoint, _ r: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                }

                // Range rings
                for i in 1...4 {
                    let r = R * CGFloat(i) / 4
                    ctx.stroke(circle(c, r), with: .color(.white.opacity(0.06)), lineWidth: 1)
                }

                // Slow sweep
                let sweep = (t * 0.35).truncatingRemainder(dividingBy: 2 * .pi)
                var beam = Path()
                beam.move(to: c)
                beam.addArc(center: c, radius: R, startAngle: .radians(sweep - 0.5),
                            endAngle: .radians(sweep), clockwise: false)
                beam.closeSubpath()
                ctx.fill(beam, with: .color(.cyan.opacity(playing ? 0.05 : 0.025)))

                // Air haze around the listener
                let haze = R * (0.10 + 0.25 * air)
                ctx.fill(circle(c, haze), with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.10 + 0.25 * air), .clear]),
                    center: c, startRadius: 0, endRadius: haze))

                for s in sources {
                    let angle = Double(s.seed % 3600) / 3600 * 2 * .pi
                    let jit = s.jitterNorm
                    let wobble = jit * 7 * sin(t * (1.5 + jit * 9) + Double(s.seed % 100))
                    let r = R * (0.10 + 0.88 * (1 - s.level)) + wobble
                    let p = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
                    let dot = 2.5 + s.level * 9

                    if s.voice != nil {
                        let hue = Double(s.midi % 12) / 12
                        let col = Color(hue: hue, saturation: 0.65, brightness: 1)
                        var tether = Path(); tether.move(to: c); tether.addLine(to: p)
                        ctx.stroke(tether, with: .color(col.opacity(0.10 + 0.25 * s.level)), lineWidth: 1)
                        let glow = dot * (3 + 1.5 * jit * (0.5 + 0.5 * sin(t * 6 + Double(s.seed % 50))))
                        ctx.fill(circle(p, glow), with: .radialGradient(
                            Gradient(colors: [col.opacity(0.45), .clear]),
                            center: p, startRadius: 0, endRadius: glow))
                        ctx.fill(circle(p, dot), with: .color(col))
                        // Ripple outward each time this device's loop sings a note
                        let age = up - s.lastNote
                        if age >= 0 && age < 5 {
                            let rr = dot + age * 16
                            ctx.stroke(circle(p, rr), with: .color(col.opacity(0.55 * (1 - age / 5))), lineWidth: 1.2)
                        }
                    } else {
                        ctx.fill(circle(p, dot * 0.7), with: .color(.white.opacity(0.18 + 0.4 * s.level)))
                    }
                }

                // Listener
                ctx.fill(circle(c, 4), with: .color(.white))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
