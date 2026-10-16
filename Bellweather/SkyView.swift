import SwiftUI

/// The sky, drawn live: colour from the sun's altitude, dimmed by cloud and rain; stars at
/// night; the sun and moon (with its phase) placed by altitude and hour angle; clouds drifting
/// with the wind; hills; rain streaks or snowflakes; a ripple for every melody note; a ring for
/// every bell strike; fog when it's damp and grey.
struct SkyView: View {
    @ObservedObject var model: SkyModel

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let up = ProcessInfo.processInfo.systemUptime
                draw(ctx: ctx, size: size, t: t, up: up)
            }
        }
    }

    private struct RGB { var r, g, b: Double }
    private func mix(_ a: RGB, _ b: RGB, _ x: Double) -> RGB {
        let k = min(1, max(0, x))
        return RGB(r: a.r + (b.r - a.r) * k, g: a.g + (b.g - a.g) * k, b: a.b + (b.b - a.b) * k)
    }
    private func color(_ c: RGB, _ o: Double = 1) -> Color { Color(red: c.r, green: c.g, blue: c.b).opacity(o) }

    private func draw(ctx: GraphicsContext, size: CGSize, t: Double, up: Double) {
        let W = size.width, H = size.height
        let horizon = H * 0.72
        let w = model.weather
        let cloud = w.cloud / 100, precip = w.precip / 100
        let alt = model.sunAlt

        // Sky gradient by sun altitude
        let nightTop = RGB(r: 0.01, g: 0.02, b: 0.07), nightBot = RGB(r: 0.05, g: 0.07, b: 0.16)
        let twiTop = RGB(r: 0.10, g: 0.12, b: 0.32), twiBot = RGB(r: 0.88, g: 0.48, b: 0.36)
        let dayTop = RGB(r: 0.22, g: 0.48, b: 0.86), dayBot = RGB(r: 0.66, g: 0.80, b: 0.95)
        var top: RGB, bot: RGB
        if alt < -10 { top = nightTop; bot = nightBot }
        else if alt < 0 { let x = (alt + 10) / 10; top = mix(nightTop, twiTop, x); bot = mix(nightBot, twiBot, x) }
        else { let x = alt / 14; top = mix(twiTop, dayTop, x); bot = mix(twiBot, dayBot, x) }
        // Cloud greys it out; rain darkens it
        let lum = 0.25 + 0.55 * model.day
        let grey = RGB(r: 0.52 * lum, g: 0.55 * lum, b: 0.6 * lum)
        top = mix(top, grey, cloud * 0.7); bot = mix(bot, grey, cloud * 0.7)
        let dark = 1 - precip * 0.35
        top = RGB(r: top.r * dark, g: top.g * dark, b: top.b * dark)
        bot = RGB(r: bot.r * dark, g: bot.g * dark, b: bot.b * dark)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)),
                 with: .linearGradient(Gradient(colors: [color(top), color(bot)]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))

        // Stars
        if alt < -4 {
            let a = min(1, (-4 - alt) / 8) * (1 - cloud * 0.95)
            if a > 0.02 {
                var seed: UInt32 = 7
                for _ in 0..<120 {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let x = CGFloat(Double((seed >> 8) & 0xFFFF) / 65_535) * W
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let y = CGFloat(Double((seed >> 8) & 0xFFFF) / 65_535) * horizon * 0.95
                    let tw = 0.6 + 0.4 * sin(t * 1.3 + Double(seed % 100))
                    let r = CGFloat(0.6 + Double(seed % 3) * 0.4)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .color(.white.opacity(a * tw * 0.9)))
                }
            }
        }

        // Sun and moon
        func place(_ ha: Double, _ alt: Double) -> CGPoint {
            CGPoint(x: W * CGFloat(0.5 + ha / Double.pi * 0.5), y: horizon - CGFloat(alt / 70) * horizon * 0.9)
        }
        if alt > -6 {
            let p = place(model.sunHA, alt)
            let r = W * 0.05
            let o = (1 - cloud * 0.75) * min(1, (alt + 6) / 6)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)),
                     with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.85, blue: 0.6).opacity(0.35 * o), .clear]),
                                           center: p, startRadius: 0, endRadius: r * 3))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(Color(red: 1, green: 0.93, blue: 0.78).opacity(o)))
        }
        if model.moonAlt > -2 {
            let p = place(model.moonHA, model.moonAlt)
            let r = W * 0.032
            let o = (1 - cloud * 0.8) * (alt < 0 ? 1 : 0.45)
            let disc = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(disc, with: .color(Color(white: 0.95).opacity(o)))
            // Phase: shade with an offset disc (0 new … 0.5 full … 1 new)
            let ph = model.moonPhase
            let lit = 1 - abs(ph - 0.5) * 2            // 0 new, 1 full
            let shift = r * 2 * CGFloat(lit) * (ph < 0.5 ? -1 : 1)
            var shade = ctx
            shade.clip(to: disc)
            shade.fill(Path(ellipseIn: CGRect(x: p.x - r + shift, y: p.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(color(top).opacity(0.92 * o)))
        }

        // Clouds drifting with the wind
        let count = Int((cloud * 11).rounded())
        let cloudCol = Color(white: 0.55 + 0.4 * model.day)
        for i in 0..<count {
            let speed = (0.004 + w.wind * 0.0012) * (1 + Double(i % 3) * 0.3)
            var x = (Double(i) * 0.37 + t * speed).truncatingRemainder(dividingBy: 1.4) - 0.2
            if x < -0.2 { x += 1.4 }
            let y = horizon * CGFloat(0.12 + 0.55 * (Double((i * 7919) % 100) / 100))
            let cw = W * CGFloat(0.18 + 0.1 * Double(i % 4))
            let cx = CGFloat(x) * W
            for j in 0..<4 {
                let dx = CGFloat(j) * cw * 0.22 - cw * 0.33
                let dy = CGFloat(j % 2) * -cw * 0.08
                let rr = cw * (0.22 + 0.05 * CGFloat((i + j) % 3))
                ctx.fill(Path(ellipseIn: CGRect(x: cx + dx - rr, y: y + dy - rr * 0.6, width: rr * 2, height: rr * 1.2)),
                         with: .color(cloudCol.opacity(0.10 + 0.18 * cloud)))
            }
        }

        // Hills
        for layer in 0..<2 {
            var hill = Path()
            hill.move(to: CGPoint(x: 0, y: H))
            let base = horizon + CGFloat(layer) * H * 0.07
            for s in 0...48 {
                let x = W * CGFloat(s) / 48
                let u = Double(s) / 48
                let y = base - CGFloat(18 * sin(u * 5.1 + Double(layer) * 2) + 12 * sin(u * 11.3 + 1)) * (layer == 0 ? 1 : 0.6)
                hill.addLine(to: CGPoint(x: x, y: y))
            }
            hill.addLine(to: CGPoint(x: W, y: H))
            hill.closeSubpath()
            let shade = 0.05 + 0.18 * model.day - Double(layer) * 0.03
            ctx.fill(hill, with: .color(Color(red: shade * 0.7, green: shade, blue: shade * 0.9)))
        }

        // Ripples, one per melody note, on the near ground
        for rp in model.ripples {
            let age = up - rp.t
            let life = rp.snow ? 4.2 : 2.4
            guard age >= 0 && age < life else { continue }
            let k = age / life
            let cx = W * CGFloat(rp.x), cy = horizon + H * 0.16
            let rx = W * CGFloat(0.02 + 0.18 * k), ry = rx * 0.28
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)),
                       with: .color(.white.opacity(0.55 * (1 - k))), lineWidth: 1.2)
        }

        // Bell ring
        let ba = up - model.bellRingAt
        if ba >= 0 && ba < 3.5 {
            let k = ba / 3.5
            let r = W * CGFloat(0.05 + 0.6 * k)
            let c = CGPoint(x: W / 2, y: horizon * 0.45)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                       with: .color(Color(red: 1, green: 0.9, blue: 0.7).opacity(0.5 * (1 - k))), lineWidth: 2)
        }

        // Rain or snow
        let drops = Int(min(170, 260 * precip * (precip > 0.15 ? 1 : 0)))
        let slant = w.wind * 0.012
        for i in 0..<drops {
            let fx = Double((i * 7_919) % 1000) / 1000
            let fy = Double((i * 104_729) % 1000) / 1000
            if model.isSnow {
                let fall = 0.05 + 0.03 * Double(i % 5)
                var y = (fy + t * fall).truncatingRemainder(dividingBy: 1)
                if y < 0 { y += 1 }
                let x = (fx + sin(t * 0.7 + Double(i)) * 0.01 + y * slant).truncatingRemainder(dividingBy: 1)
                let r = CGFloat(1.2 + Double(i % 3) * 0.6)
                let px = CGFloat(x) * W, py = CGFloat(y) * H
                ctx.fill(Path(ellipseIn: CGRect(x: px - r, y: py - r, width: 2 * r, height: 2 * r)),
                         with: .color(.white.opacity(0.75)))
            } else {
                let fall = 0.9 + 0.3 * Double(i % 4)
                let y = (fy + t * fall).truncatingRemainder(dividingBy: 1)
                let x = (fx + y * slant).truncatingRemainder(dividingBy: 1)
                var streak = Path()
                let px = CGFloat(x) * W, py = CGFloat(y) * H
                streak.move(to: CGPoint(x: px, y: py))
                streak.addLine(to: CGPoint(x: px - CGFloat(slant) * 14, y: py + 12))
                ctx.stroke(streak, with: .color(Color(red: 0.75, green: 0.82, blue: 0.95).opacity(0.35)), lineWidth: 1)
            }
        }

        // Fog
        if w.humidity > 70 && cloud > 0.6 {
            let a = (w.humidity - 70) / 30 * 0.4
            ctx.fill(Path(CGRect(x: 0, y: horizon * 0.5, width: W, height: H - horizon * 0.5)),
                     with: .linearGradient(Gradient(colors: [.clear, Color(white: 0.85).opacity(a)]),
                                           startPoint: CGPoint(x: 0, y: horizon * 0.5),
                                           endPoint: CGPoint(x: 0, y: H)))
        }
    }
}
