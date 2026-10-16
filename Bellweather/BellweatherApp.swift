import SwiftUI
import AVKit

@main
struct BellweatherApp: App {
    var body: some Scene {
        WindowGroup { BellContentView() }
    }
}

private let pitchNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

struct BellContentView: View {
    @StateObject private var model = SkyModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    SkyView(model: model)
                        .ignoresSafeArea(edges: .top)
                    header.padding(.horizontal, 16).padding(.top, 8)
                }
                .frame(maxHeight: .infinity)
                controls
                    .padding(16)
                    .background(Color(white: 0.04))
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            BellSettingsView(model: model).presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BELL WEATHER")
                    .font(.system(size: 20, weight: .light, design: .serif))
                    .tracking(5)
                Text(model.status).font(.caption).foregroundStyle(.white.opacity(0.75))
                if let partner = model.partnerName {
                    Label("Duo with \(partner)", systemImage: "link")
                        .font(.caption2).foregroundStyle(.cyan)
                }
            }
            Spacer()
            BellAirPlayButton().frame(width: 30, height: 30)
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
            .tint(.white)
        }
        .shadow(color: .black.opacity(0.4), radius: 4)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                reading(String(format: "%.0f°", model.weather.temp), "temp")
                reading(String(format: "%.0f", model.weather.wind), "wind mph")
                reading(String(format: "%.0f%%", model.weather.humidity), "humidity")
                reading(String(format: "%.0f%%", model.weather.precip), model.isSnow ? "snow" : "rain")
                reading(String(format: "%.0f%%", model.weather.cloud), "cloud")
            }
            HStack(spacing: 10) {
                Button(action: model.togglePlay) {
                    Label(model.isPlaying ? "Fade out" : "Begin",
                          systemImage: model.isPlaying ? "stop.fill" : "cloud.sun")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isPlaying ? Color.white.opacity(0.15) : Color.orange.opacity(0.75))
                Button(action: model.strikeBell) {
                    Image(systemName: "bell")
                        .font(.headline)
                        .frame(width: 28)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.white.opacity(0.12))
                .disabled(!model.isPlaying)
                .accessibilityLabel("Strike bell")
            }
        }
    }

    private func reading(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.body, design: .monospaced))
            Text(label).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BellSettingsView: View {
    @ObservedObject var model: SkyModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Sky") {
                    Picker("Weather", selection: $model.useLiveWeather) {
                        Text("Live").tag(true)
                        Text("Simulated").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Hourly bell", isOn: $model.hourlyBell)
                    Toggle("Drone drift", isOn: $model.driftOn)
                }
                Section {
                    Picker("Scale", selection: $model.scaleIndex) {
                        ForEach(DuoScales.all.indices, id: \.self) { Text(DuoScales.all[$0].name).tag($0) }
                    }
                    Picker("Root", selection: $model.rootPC) {
                        ForEach(0..<12, id: \.self) { Text(pitchNames[$0]).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Melody octave: \(model.octave > 0 ? "+" : "")\(model.octave)")
                        Slider(value: Binding(get: { Double(model.octave) },
                                              set: { model.octave = Int($0.rounded()) }),
                               in: -1...2, step: 1)
                    }
                    Toggle("Melody", isOn: $model.melodyOn)
                    Picker("Voice", selection: $model.voice) {
                        ForEach(MelodyVoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Tempo: %.0f BPM", model.effectiveBPM))
                        Slider(value: $model.bpm, in: 40...200, step: 1)
                            .disabled(model.partnerName != nil && model.followTempo)
                    }
                } header: {
                    Text("Music")
                } footer: {
                    Text("Seven single-note loops on long, unequal periods (Airports-style). Rain makes them busier and louder; snow turns them soft and slow. Tempo sets the echo.")
                }
                Section {
                    DuoControls(duo: model.duo, partnerName: "Aether")
                    if let summary = model.partnerSummary {
                        Text(summary).font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Follow Aether's tempo", isOn: $model.followTempo)
                    Toggle("Drone follows Aether's chords", isOn: $model.followChords)
                } header: {
                    Text("Duo")
                } footer: {
                    Text("With Aether on another iPhone nearby, this sky leads the harmony (Aether takes your key and scale) and the radio room leads time: its tempo sets the echo, its chord changes steer the drone, and a crowded room livens the melody. The search stops after the time you choose, to save battery.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct BellAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemOrange
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
