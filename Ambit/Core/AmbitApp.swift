import SwiftUI
import AVKit

@main
struct AmbitApp: App {
    var body: some Scene {
        WindowGroup { AmbitRoot() }
    }
}

/// The pad, and each instrument's page sliding in over it.
///
/// Tapping an instrument on the pad moves toward it: the pad slides out on the instrument's
/// side and the page follows in from the opposite edge (Orbitakt, above, rises from the
/// bottom; Leitmotif, to the right, comes in from the left). The back button reverses it.
struct AmbitRoot: View {
    @StateObject private var ensemble = Ensemble()
    @State private var open: Layer?
    @Environment(\.scenePhase) private var scenePhase

    private let slide = Animation.spring(response: 0.5, dampingFraction: 0.92)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AmbitHome(onOpen: { l in withAnimation(slide) { open = l } })
                    .offset(homeOffset(geo.size))
                    .allowsHitTesting(open == nil)

                if let l = open {
                    page(l)
                        .safeAreaInset(edge: .top, spacing: 0) { backBar(l) }
                        .transition(.move(edge: l.entryEdge))
                        .zIndex(1)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .environmentObject(ensemble)
        .onChange(of: scenePhase) { _, phase in ensemble.scenePhaseChanged(phase) }
    }

    /// While a page is open, the pad has slid out on that instrument's side.
    private func homeOffset(_ size: CGSize) -> CGSize {
        guard let l = open else { return .zero }
        return CGSize(width: l.direction.dx * size.width, height: l.direction.dy * size.height)
    }

    @ViewBuilder private func page(_ l: Layer) -> some View {
        switch l {
        case .aether: AetherPanel(model: ensemble.field)
        case .bell: BellPanel(model: ensemble.sky)
        case .motif: LeitmotifPanel(model: ensemble.motif)
        case .orbit: OrbitPanel(model: ensemble.orbit)
        }
    }

    private func backBar(_ l: Layer) -> some View {
        HStack {
            Button { withAnimation(slide) { open = nil } } label: {
                Label("Ambit", systemImage: l.backIcon)
                    .font(.subheadline.weight(.medium))
            }
            .tint(l.color)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.35))
    }
}

// MARK: - Home

struct AmbitHome: View {
    @EnvironmentObject private var ensemble: Ensemble
    let onOpen: (Layer) -> Void
    @State private var showSettings = false
    @State private var showAbout = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.02, blue: 0.06), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    MixPad(onOpen: onOpen)
                    transport
                    VStack(spacing: 0) {
                        AetherRow(model: ensemble.field)
                        Divider().opacity(0.2)
                        BellRow(model: ensemble.sky)
                        Divider().opacity(0.2)
                        MotifRow(model: ensemble.motif)
                        Divider().opacity(0.2)
                        OrbitRow(model: ensemble.orbit)
                    }
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
                    Text("In the background, Leitmotif, Bellweathered and Orbitakt carry on live and in step. iOS stops Bluetooth scanning for apps out of view, so Aether holds the last room it heard and plays it until you're back.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $showSettings) {
            AmbitSettings().presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAbout) {
            AboutAmbit().presentationDetents([.large])
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AMBIT")
                    .font(.system(size: 22, weight: .light, design: .monospaced))
                    .tracking(8)
                ConductorLine(sky: ensemble.sky, field: ensemble.field)
                Button { showAbout = true } label: {
                    Label("What is this?", systemImage: "questionmark.circle")
                        .font(.caption2)
                }
                .tint(Color(red: 0.75, green: 0.72, blue: 1.0))
                .padding(.top, 1)
            }
            Spacer()
            AmbitAirPlayButton().frame(width: 30, height: 30)
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
            .tint(.white)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 8)
    }

    private var transport: some View {
        Button {
            if ensemble.anyPlaying { ensemble.stopAll() } else { ensemble.playAll() }
        } label: {
            Label(ensemble.anyPlaying ? "Fade out" : "Play",
                  systemImage: ensemble.anyPlaying ? "stop.fill" : "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(ensemble.anyPlaying ? Color.white.opacity(0.15) : Color(red: 0.55, green: 0.5, blue: 0.95).opacity(0.85))
    }
}

/// The ensemble's harmony and time at a glance: the sky's key, the room's tempo and chord.
private struct ConductorLine: View {
    @ObservedObject var sky: SkyModel
    @ObservedObject var field: FieldModel

    var body: some View {
        let scale = DuoScales.all[max(0, min(DuoScales.all.count - 1, sky.scaleIndex))].name
        Text("\(pitchNames[sky.rootPC]) \(scale.lowercased()) · \(Int(field.bpm.rounded())) BPM · chord \(field.chordName.isEmpty ? "–" : field.chordName)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - The mix pad

/// A joystick in the middle with the four instruments around it: space above (Orbitakt),
/// land below (Bellweathered), the melody to the right (Leitmotif) and the radio room to the
/// left (Aether). Drag the puck to lean the mix; double-tap the pad to centre it. Tap an
/// instrument to open it.
struct MixPad: View {
    @EnvironmentObject private var ensemble: Ensemble
    let onOpen: (Layer) -> Void

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let R = side * 0.27                 // the puck's travel
            let reach = side * 0.405            // where the instruments sit
            let tile = side * 0.19
            let gains = ensemble.gains

            ZStack {
                PadBackdrop(gains: gains, puck: ensemble.puck, radius: R, reach: reach)

                // The pad itself: drag anywhere inside to move the puck.
                Circle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: 2 * R + 30, height: 2 * R + 30)
                    .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { v in
                        var p = CGPoint(x: (v.location.x - (R + 15)) / R, y: (v.location.y - (R + 15)) / R)
                        let r = sqrt(p.x * p.x + p.y * p.y)
                        if r > 1 { p = CGPoint(x: p.x / r, y: p.y / r) }
                        ensemble.puck = p
                    })
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { ensemble.puck = .zero }
                    })
                    .accessibilityElement()
                    .accessibilityLabel("Mix pad")
                    .accessibilityValue(accessibilityMix(gains))
                    .position(c)

                Puck()
                    .frame(width: 34, height: 34)
                    .position(x: c.x + ensemble.puck.x * R, y: c.y + ensemble.puck.y * R)
                    .allowsHitTesting(false)

                ForEach(Layer.allCases) { l in
                    InstrumentTile(layer: l, gain: gains[l.rawValue], playing: ensemble.isPlaying(l))
                        .frame(width: tile, height: tile)
                        .position(x: c.x + l.direction.dx * reach, y: c.y + l.direction.dy * reach)
                        .onTapGesture { onOpen(l) }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func accessibilityMix(_ g: [Double]) -> String {
        Layer.allCases.map { "\($0.name) \(Int((g[$0.rawValue] * 100).rounded()))%" }.joined(separator: ", ")
    }
}

/// Space above, land below: a starfield over the horizon and dusky ground under it, the
/// pad's rings and crosshair, each instrument's glow (as bright as its share of the mix) and
/// a thread from the puck to each one.
private struct PadBackdrop: View {
    let gains: [Double]
    let puck: CGPoint
    let radius: CGFloat
    let reach: CGFloat

    private static let stars: [(CGFloat, CGFloat, CGFloat)] = {
        var x: UInt64 = 0x9E3779B97F4A7C15
        func next() -> CGFloat {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return CGFloat(x % 10_000) / 10_000
        }
        return (0..<70).map { _ in (next(), next() * 0.5, 0.4 + 1.2 * next()) }
    }()

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let full = CGRect(origin: .zero, size: size)
            let rounded = Path(roundedRect: full, cornerRadius: 22)
            ctx.clip(to: rounded)

            // Sky above the horizon: deep space fading to a dusk glow at the horizon.
            let sky = CGRect(x: 0, y: 0, width: size.width, height: c.y)
            ctx.fill(Path(sky), with: .linearGradient(
                Gradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.1), Color(red: 0.06, green: 0.06, blue: 0.18),
                                  Color(red: 0.24, green: 0.14, blue: 0.24)]),
                startPoint: CGPoint(x: c.x, y: 0), endPoint: CGPoint(x: c.x, y: c.y)))
            for (sx, sy, r) in PadBackdrop.stars {
                let p = CGPoint(x: sx * size.width, y: sy * size.height * 0.96)
                let fade = 1 - sy * 1.6   // fewer, dimmer stars toward the horizon
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r)),
                         with: .color(.white.opacity(Double(max(0.1, fade)) * 0.8)))
            }
            // Land below: warm at the horizon, earth toward the bottom.
            let land = CGRect(x: 0, y: c.y, width: size.width, height: size.height - c.y)
            ctx.fill(Path(land), with: .linearGradient(
                Gradient(colors: [Color(red: 0.2, green: 0.13, blue: 0.1), Color(red: 0.07, green: 0.08, blue: 0.05),
                                  Color(red: 0.03, green: 0.03, blue: 0.02)]),
                startPoint: CGPoint(x: c.x, y: c.y), endPoint: CGPoint(x: c.x, y: size.height)))
            var horizon = Path()
            horizon.move(to: CGPoint(x: 0, y: c.y))
            horizon.addLine(to: CGPoint(x: size.width, y: c.y))
            ctx.stroke(horizon, with: .color(Color(red: 1, green: 0.75, blue: 0.5).opacity(0.25)), lineWidth: 1)

            // Each instrument's glow, as bright as its share of the mix.
            for l in Layer.allCases {
                let p = CGPoint(x: c.x + l.direction.dx * reach, y: c.y + l.direction.dy * reach)
                let g = gains[l.rawValue]
                let r = radius * 0.95
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .radialGradient(Gradient(colors: [l.color.opacity(0.45 * g), .clear]),
                                               center: p, startRadius: 0, endRadius: r))
            }

            // The pad: rings and a crosshair.
            for k in [0.5, 1.0] {
                let r = radius * k
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(.white.opacity(k == 1 ? 0.22 : 0.1)), lineWidth: 1)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - radius, y: c.y)); cross.addLine(to: CGPoint(x: c.x + radius, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - radius)); cross.addLine(to: CGPoint(x: c.x, y: c.y + radius))
            ctx.stroke(cross, with: .color(.white.opacity(0.08)), lineWidth: 1)

            // A thread from the puck to each instrument, thicker the more it's heard.
            let pk = CGPoint(x: c.x + puck.x * radius, y: c.y + puck.y * radius)
            for l in Layer.allCases {
                let g = gains[l.rawValue]
                let end = CGPoint(x: c.x + l.direction.dx * (reach - radius * 0.38),
                                  y: c.y + l.direction.dy * (reach - radius * 0.38))
                var line = Path()
                line.move(to: pk)
                line.addLine(to: end)
                ctx.stroke(line, with: .color(l.color.opacity(0.15 + 0.6 * g)), lineWidth: 0.5 + 3 * g)
            }
        }
    }
}

private struct Puck: View {
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [.white.opacity(0.5), .clear],
                                         center: .center, startRadius: 0, endRadius: 24))
                .scaleEffect(1.6)
            Circle().fill(Color.white.opacity(0.92))
            Circle().stroke(Color.black.opacity(0.3), lineWidth: 1).padding(6)
        }
        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }
}

/// An instrument on the pad, as an element tile like its app icon.
private struct InstrumentTile: View {
    let layer: Layer
    let gain: Double
    let playing: Bool

    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.16)
                    .fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: s * 0.16)
                    .stroke(layer.color.opacity(playing ? 0.35 + 0.65 * gain : 0.25), lineWidth: playing ? 1.5 : 1)
                VStack(spacing: 0) {
                    HStack {
                        Text("\(layer.number)").font(.system(size: s * 0.13, design: .monospaced))
                        Spacer()
                        Circle().fill(playing ? layer.color : Color.white.opacity(0.15))
                            .frame(width: s * 0.08, height: s * 0.08)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 0)
                    Text(layer.symbol)
                        .font(.system(size: s * 0.38, weight: .light))
                        .foregroundStyle(.white)
                        .shadow(color: layer.color.opacity(playing ? 0.9 : 0.3), radius: s * 0.08)
                    Spacer(minLength: 0)
                    Text(layer.name)
                        .font(.system(size: s * 0.1))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(layer.color.opacity(playing ? 1 : 0.6))
                }
                .padding(s * 0.09)
            }
            .opacity(playing ? 1 : 0.7)
        }
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel("\(layer.name), \(playing ? "playing" : "off")")
        .accessibilityHint("Opens \(layer.name)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Instrument rows (level and on/off)

private struct LayerRow: View {
    @EnvironmentObject private var ensemble: Ensemble
    let layer: Layer
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(layer.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(layer.name).font(.subheadline)
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { ensemble.isPlaying(layer) },
                                         set: { ensemble.setLayer(layer, on: $0) }))
                    .labelsHidden()
                    .tint(layer.color)
                    .accessibilityLabel("\(layer.name) on")
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { ensemble.trims[layer.rawValue] },
                                      set: { ensemble.trims[layer.rawValue] = $0 }), in: 0...1)
                    .tint(layer.color.opacity(0.8))
                    .accessibilityLabel("\(layer.name) level")
                Text("\(Int((ensemble.gains[layer.rawValue] * 100).rounded()))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct AetherRow: View {
    @ObservedObject var model: FieldModel
    var body: some View {
        let heard = model.sources.filter { $0.level > 0.03 }.count
        LayerRow(layer: .aether,
                 status: model.isHeld ? "Holding the last room it heard"
                     : "\(heard) emitters · \(model.voicedCount) voices · air \(Int((model.air * 100).rounded()))%")
    }
}

private struct BellRow: View {
    @ObservedObject var model: SkyModel
    var body: some View {
        let w = model.weather
        LayerRow(layer: .bell,
                 status: "\(Int(w.temp.rounded()))°F · \(Int(w.cloud.rounded()))% cloud · wind \(Int(w.wind.rounded())) mph")
    }
}

private struct MotifRow: View {
    @ObservedObject var model: LeitmotifModel
    var body: some View {
        LayerRow(layer: .motif, status: "\(model.perMinute) per minute · \(model.status)")
    }
}

private struct OrbitRow: View {
    @ObservedObject var model: RhythmModel
    var body: some View {
        var s = "\(model.snapshot.blips.count) overhead · \(Int(model.effectiveBPM.rounded())) BPM"
        if let crew = model.crewNote { s += " · \(crew)" }
        return LayerRow(layer: .orbit, status: s)
    }
}

// MARK: - Shared controls

/// The big play button on each instrument's page: brings that instrument in or out of the mix.
struct LayerPlayButton: View {
    @EnvironmentObject private var ensemble: Ensemble
    let layer: Layer
    let playing: Bool
    let start: String
    let icon: String

    var body: some View {
        Button { ensemble.setLayer(layer, on: !playing) } label: {
            Label(playing ? "Fade out" : start, systemImage: playing ? "stop.fill" : icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(playing ? Color.white.opacity(0.15) : layer.color.opacity(0.75))
    }
}

private struct AmbitSettings: View {
    @EnvironmentObject private var ensemble: Ensemble
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Keep the screen on while playing", isOn: $ensemble.keepAwake)
                } footer: {
                    Text("Aether only hears the radio room while Ambit is in front, so keep the screen on for a live room. Leave it off to let Ambit play in your pocket: Leitmotif, Bellweathered and Orbitakt carry on live, and Aether holds the room it last heard.")
                }
                Section {
                    Button("Centre the mix") {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { ensemble.puck = .zero }
                    }
                } footer: {
                    Text("In the middle all four play equally. Drag the puck toward one to favour it; all the way to the rim and only that one plays. Along the rim between two, it crossfades between just those two. Loudness stays even across the pad. Double-tap the pad to centre it. Each instrument's level and switch are under the pad; tap an instrument to open it.")
                }
                Section {
                    ForEach(Layer.allCases) { l in
                        HStack {
                            Circle().fill(l.color).frame(width: 7, height: 7)
                            Text(l.name)
                            Spacer()
                            Text(loadText(l))
                                .monospacedDigit()
                                .foregroundStyle(ensemble.loads[l.rawValue] > 0.35 ? Color.orange : Color.secondary)
                        }
                    }
                } header: {
                    Text("Audio load")
                } footer: {
                    Text("How much of each audio buffer's time each instrument's synth takes to render (effects not included). All four share one real-time audio thread; together they should stay well under 100%. Instruments that are off, or pushed to zero on the pad, cost nothing.")
                }
                Section {
                    LabeledContent("Key", value: "Bellweathered (the sky)")
                    LabeledContent("Tempo and chords", value: "Aether (the radio room)")
                } header: {
                    Text("Who leads")
                } footer: {
                    Text("Set the ensemble's key in Bellweathered's settings. Each instrument can stop following in its own settings.")
                }
            }
            .navigationTitle("Ambit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { ensemble.refreshLoads() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            ensemble.refreshLoads()
        }
    }

    private func loadText(_ l: Layer) -> String {
        guard ensemble.isPlaying(l) else { return "off" }
        if ensemble.gains[l.rawValue] == 0 { return "parked" }
        return String(format: "%.0f%%", ensemble.loads[l.rawValue] * 100)
    }
}

private struct AmbitAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemPurple
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
