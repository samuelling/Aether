import SwiftUI

@main
struct AetherApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var model = FieldModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.07), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    RadarView(sources: model.sources, air: model.air, playing: model.isPlaying)
                        .padding(.horizontal, 4)
                    stats
                    playButton
                    sourceList
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: model.isPlaying) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AETHER")
                    .font(.system(size: 22, weight: .light, design: .monospaced))
                    .tracking(6)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
            .tint(.white)
        }
        .padding(.top, 8)
    }

    private var stats: some View {
        HStack {
            stat("\(model.sources.filter { $0.level > 0.03 }.count)", "emitters")
            stat("\(model.voicedCount)", "voices")
            stat(model.isPlaying ? model.chordName : "–", "chord")
            stat(String(format: "%.0f%%", model.air * 100), "air")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title3, design: .monospaced))
            Text(label).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }

    private var playButton: some View {
        Button(action: model.togglePlay) {
            Label(model.isPlaying ? "Fade out" : "Listen",
                  systemImage: model.isPlaying ? "stop.fill" : "waveform")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isPlaying ? Color.white.opacity(0.15) : Color.cyan.opacity(0.7))
    }

    private var sourceList: some View {
        VStack(spacing: 0) {
            ForEach(model.sources.prefix(14)) { s in
                SourceRow(source: s)
                Divider().opacity(0.25)
            }
        }
    }
}

private struct SourceRow: View {
    let source: RadioSource

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(source.voice != nil
                      ? Color(hue: Double(source.midi % 12) / 12, saturation: 0.65, brightness: 1)
                      : Color.white.opacity(0.2))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.label).font(.subheadline).lineLimit(1)
                Text(source.voice != nil ? noteNames[source.midi % 12] + "\(source.midi / 12 - 1)" : "listening")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Jitter meter: how disturbed this path is
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Color.orange.opacity(0.8))
                        .frame(width: max(2, geo.size.width * source.jitterNorm))
                }
            }
            .frame(width: 44, height: 4)
            Text(String(format: "%4.0f", source.fast))
                .font(.caption.monospaced())
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: FieldModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Tuning") {
                    Picker("Scale", selection: $model.scale) {
                        ForEach(DroneScale.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Root", selection: $model.rootNote) {
                        ForEach(0..<12, id: \.self) { Text(noteNames[$0]).tag($0) }
                    }
                }
                Section {
                    Stepper("Voices: \(model.voiceLimit)", value: $model.voiceLimit, in: 1...DroneParams.voiceCount)
                    VStack(alignment: .leading) {
                        Text("Reach: \(Int(model.floorDBm)) dBm")
                        Slider(value: $model.floorDBm, in: -105 ... -70, step: 1)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Response")
                            Spacer()
                            Text(String(format: "≈ %.1f s lag", model.approxLagSeconds))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $model.response, in: 0.15...1.0) {
                            Text("Response")
                        } minimumValueLabel: {
                            Text("Tight").font(.caption2)
                        } maximumValueLabel: {
                            Text("Drift").font(.caption2)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Chord change every \(Int(model.chordSeconds)) s")
                        Slider(value: $model.chordSeconds, in: 12...90, step: 2)
                    }
                } header: {
                    Text("Field")
                } footer: {
                    Text("Each voiced device sings its own short phrase on its own loop length. Reach sets the faintest signal that still sings: lower it to hear the neighbors, raise it to hear only the room. Response sets how quickly the sound follows the field: Tight for demonstrating (cup the phone and hear it dim), Drift for listening.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
