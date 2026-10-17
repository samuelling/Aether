import SwiftUI

/// Colours for who the phone was talking to.
extension LookupKind {
    var color: Color {
        switch self {
        case .app: return Color(red: 1.0, green: 0.72, blue: 0.36)
        case .system: return Color(red: 0.55, green: 0.66, blue: 0.95)
        case .tracker: return Color(red: 1.0, green: 0.36, blue: 0.62)
        }
    }
}

/// Leitmotif's own page inside Ambit: the soloist, the meter, and the ledger of what it sang.
struct LeitmotifPanel: View {
    @ObservedObject var model: LeitmotifModel
    @State private var showSettings = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.03, blue: 0.07), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    VoiceOrb(voice: model.voice, whisper: model.whisper, playing: model.isPlaying)
                        .frame(height: 120)
                    stats
                    playButton
                    ledger
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            LeitmotifSettings(model: model).presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LEITMOTIF NAME")
                    .font(.system(size: 22, weight: .light, design: .monospaced))
                    .tracking(5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.harmonyLine)
                    .font(.caption2)
                    .foregroundStyle(model.partnerName != nil ? Color.cyan : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
            .tint(.white)
        }
        .padding(.top, 12)
    }

    private var stats: some View {
        HStack {
            stat(model.meterWorks ? rate(model.down) : "—", "down")
            stat(model.meterWorks ? rate(model.up) : "—", "up")
            stat("\(model.perMinute)", "lookups/min")
            stat("\(model.tunnel.queries)", "since start")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title3, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func rate(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.0f B/s", bps)
    }

    private var playButton: some View {
        LayerPlayButton(layer: .motif, playing: model.isPlaying, start: "Listen", icon: "ear")
    }

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ForEach([LookupKind.app, .system, .tracker], id: \.self) { k in
                    HStack(spacing: 4) {
                        Circle().fill(k.color).frame(width: 7, height: 7)
                        Text(k.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if model.lookups.isEmpty {
                Text(model.isPlaying
                     ? "Waiting for your phone to look something up. Open another app."
                     : "Every name your phone looks up will appear here, and be sung.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.lookups) { t in
                        LookupRow(lookup: t, showName: model.showNames)
                        Divider().opacity(0.25)
                    }
                }
            }
        }
    }
}

private struct LookupRow: View {
    let lookup: Lookup
    let showName: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(lookup.kind.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(showName ? lookup.domain : hidden)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                if showName && lookup.name != lookup.domain {
                    Text(lookup.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            MotifGlyph(motif: lookup.motif, color: lookup.kind.color, fate: lookup.fate)
                .frame(width: 54, height: 22)
            Text(fateMark)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
        }
        .padding(.vertical, 6)
        .opacity(lookup.fate == .dropped ? 0.45 : 1)
    }

    /// Hide the name but keep the shape: "••••••.com".
    private var hidden: String {
        let tld = lookup.domain.split(separator: ".").last.map(String.init) ?? ""
        return String(repeating: "•", count: min(10, max(3, lookup.domain.count - tld.count - 1))) + "." + tld
    }

    private var fateMark: String {
        switch lookup.fate {
        case .sung: return "♪"
        case .whispered: return "·"
        case .merged: return "↺"
        case .dropped: return "–"
        case .waiting: return "…"
        }
    }
}

/// The motif drawn as a tiny piano roll: height = scale step, width = length.
private struct MotifGlyph: View {
    let motif: [MotifNote]
    let color: Color
    let fate: Lookup.Fate

    var body: some View {
        Canvas { ctx, size in
            guard !motif.isEmpty else { return }
            let total = CGFloat(motif.reduce(0) { $0 + $1.eighths })
            let lo = motif.map(\.degree).min() ?? 0, hi = motif.map(\.degree).max() ?? 0
            let span = CGFloat(max(4, hi - lo))
            var x: CGFloat = 0
            for n in motif {
                let w = size.width * CGFloat(n.eighths) / total
                let y = size.height - 3 - (size.height - 6) * CGFloat(n.degree - lo) / span
                let r = CGRect(x: x + 1, y: y - 1.5, width: max(2, w - 2), height: 3)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1.5),
                         with: .color(color.opacity(fate == .sung || fate == .whispered ? 0.95 : 0.4)))
                x += w
            }
        }
    }
}

/// A soft glow that swells with the soloist, with a pink flicker for each whisper.
private struct VoiceOrb: View {
    let voice: Double
    let whisper: Double
    let playing: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.74, blue: 0.45).opacity(0.85), .clear],
                                     center: .center, startRadius: 2, endRadius: 60))
                .scaleEffect(0.35 + 0.9 * voice)
                .opacity(playing ? 0.25 + 0.75 * voice : 0.12)
            Circle()
                .stroke(LookupKind.tracker.color.opacity(whisper), lineWidth: 1.5)
                .scaleEffect(0.9 + 0.3 * whisper)
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.12), value: voice)
        .animation(.easeOut(duration: 0.12), value: whisper)
    }
}

struct LeitmotifSettings: View {
    @ObservedObject var model: LeitmotifModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Follow the ensemble", isOn: $model.followDuo)
                } header: {
                    Text("Ensemble")
                } footer: {
                    Text("Leitmotif takes its key from Bellweathered and its tempo and chords from Aether. They all live in Ambit, so it stays in step with them while you're in other apps or the phone is locked.")
                }

                Section("Key (when not following)") {
                    Picker("Root", selection: $model.rootPC) {
                        ForEach(0..<12, id: \.self) { Text(pitchNames[$0]).tag($0) }
                    }
                    Picker("Scale", selection: $model.scaleIndex) {
                        ForEach(DuoScales.all.indices, id: \.self) { Text(DuoScales.all[$0].name).tag($0) }
                    }
                    HStack {
                        Text("Tempo")
                        Slider(value: $model.bpm, in: 44...120, step: 1)
                        Text("\(Int(model.bpm))").monospacedDigit().frame(width: 34)
                    }
                    .disabled(model.followingTempo)
                }
                .disabled(model.followingKey)

                Section("Voice") {
                    Stepper("Octave \(model.octave >= 0 ? "+" : "")\(model.octave)", value: $model.octave, in: -2...1)
                    Toggle("Whisper the trackers", isOn: $model.whisperTrackers)
                    Toggle("Show names on screen", isOn: $model.showNames)
                    Button("Clear the list", role: .destructive) { model.clearLedger() }
                }

                Section {
                    Picker("Resolver", selection: $model.upstream) {
                        ForEach(WireUpstream.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Lookups")
                } footer: {
                    Text("While Leitmotif listens, your phone's name lookups go to this resolver instead of your Wi-Fi's or carrier's. Leitmotif keeps the names in memory only, never on disk, and closes the tunnel if the app stops asking for five minutes.")
                }
            }
            .navigationTitle("Leitmotif Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
