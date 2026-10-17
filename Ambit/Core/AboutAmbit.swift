import SwiftUI

/// "What is this?": the four instruments, where each one's data comes from, and what's done
/// with it.
struct AboutAmbit: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Ambit plays the invisible things around you as music. Four instruments each listen to a different layer of your surroundings, from the radio waves in the room to the satellites passing overhead, and play together in one key and one tempo.")
                        .font(.callout)

                    entry(.orbit, place: "Above · space",
                          source: "The satellites over your head: CelesTrak's public catalog of active satellites (fetched at most twice a day), placed in your sky with the standard SGP4 orbit model and your approximate location.",
                          mapping: "A radar beam sweeps your sky from north, once every bar or two, and each satellite near the zenith plays as the beam passes its bearing: GPS and other navigation satellites are a deep kick, low orbits a rimshot into a dub echo, Starlink metallic hats, the geostationary belt a gated hat. Something passing straight overhead rings a glass bar; the ISS or Tiangong brings a gong.")

                    entry(.motif, place: "Right · your phone",
                          source: Edition.leitmotifSource,
                          mapping: Edition.leitmotifMapping + " It plays a dusty upright piano, a soloist over the others.")

                    entry(.bell, place: "Below · the land and weather",
                          source: "Live weather where you are from Open-Meteo (temperature, cloud, humidity, wind, pressure, rain or snow), refreshed every ten minutes, plus the sun's and moon's positions and the moon's phase, worked out on the phone. With no connection it plays a simulated sky.",
                          mapping: "A six-layer drone coloured by the weather: warmth and daylight brighten it, cloud and humidity soften it, wind makes it breathe and gust. Rain or snow adds hiss; slow Airports-style melody loops get busier in rain and softer in snow; a bell rings on the solar hour. Bellweathered leads the harmony: its key and scale are everyone's.")

                    entry(.aether, place: "Left · the radio room",
                          source: "The Bluetooth signals around you: every phone, watch, earbud, TV or gadget nearby that advertises itself, and how strongly it's heard (its signal strength), several times a second. Only the strength and a scrambled identity are used, never what the device is saying.",
                          mapping: "Each device gets its own little tape loop, a phrase of one to three notes repeating every 14 to 30 seconds; no two loops line up, so the melody keeps recombining. Closer means louder and brighter, and a wobbly signal warps the tape. Underneath, a soft pad chord drifts through a progression. How restless the field is sets the tempo, so Aether leads the time and the chord changes for everyone. iOS stops Bluetooth scanning for apps out of view, so in the background Aether keeps playing the last room it heard.")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("The pad").font(.headline)
                        Text("The joystick in the middle is the mix. In the centre all four are equal; push toward one to favour it, all the way to hear only it. Tap an instrument to open its own page and settings.")
                            .font(.callout)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("What leaves your phone").font(.headline)
                        Text(Edition.name == "Ambit Name"
                             ? "Everything is computed on the phone. Ambit asks Open-Meteo for the weather at your rounded location and CelesTrak for the satellite catalog, and your phone's name lookups go to the resolver chosen in Leitmotif's settings. Nothing is recorded or sent anywhere else."
                             : "Everything is computed on the phone. Ambit asks Open-Meteo for the weather at your rounded location and CelesTrak for the satellite catalog; nothing is recorded or sent anywhere else.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("What is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func entry(_ l: Layer, place: String, source: String, mapping: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(l.symbol)
                    .font(.system(size: 17, weight: .light))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 7).stroke(l.color.opacity(0.8), lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.name).font(.headline).foregroundStyle(l.color)
                    Text(place).font(.caption).foregroundStyle(.secondary)
                }
            }
            labelled("Listens to", source)
            labelled("Plays it as", mapping)
        }
    }

    private func labelled(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }
}
