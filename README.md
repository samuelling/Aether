# Aether

An iPhone instrument that listens to the Bluetooth LE radio field around you and plays it as ambient, melodic pads, in the spirit of Brian Eno's *Music for Airports*.

Every advertising device in range (phones, watches, earbuds, TVs, the neighbors' gadgets) reports a signal strength (RSSI) several times a second on the 2.4 GHz band. Aether gives each one its own tape loop: a short melodic phrase of 1–3 notes, repeating on a loop length between 14 and 30 seconds. Because no two loops share a period, the phrases drift in and out of alignment and the melody keeps recombining. Underneath, a soft pad chord drifts slowly through a progression.

## How the radio becomes music

| Radio | Music |
|---|---|
| Each emitter's identity (hashed) | Its phrase, loop length, stereo position and radar bearing, fixed for as long as it's around |
| Signal strength | How loud and bright its notes are. Faint devices sing only the first note of their phrase; move closer and the whole phrase unfolds |
| Jitter (dB wobble around its mean) | Tape wow: the notes' pitch bends gently, like a warped cassette |
| Strongest N emitters (up to 32) | Get voices (sticky, so they don't flap between near-equals). Each voice softens as more join, so a crowded room stays a haze |
| How many emitters are around | Fullness of the pad chord |
| Whole-field motion vs. its baseline ("air") | The pad opens up and the octave-up shimmer halo swells as you move |

The signal chain is soft sine-based tones with slow swells and ~20 s releases, a long 1.35 s delay, a cathedral reverb, and a parallel octave-up hall for shimmer. There are no drones and no bells.

Moving matters because at 2.4 GHz the wavelength is ~12.5 cm. Reflections off walls interfere, so the field is full of nulls a few centimeters apart, and your body (mostly salt water) casts a radio shadow. Turning around or walking through a doorway changes who's singing.

## Piano arpeggio (optional)

Tap the piano-keys button (or Settings › Arpeggio) to add a stochastic arpeggio that wanders over the chord progression on a dusty upright.

- **The piano** is synthesized from scratch at launch, not recorded. It uses slightly sharp, stiff-string overtones, two detuned strings per note, a quick-then-long two-stage decay, a felt hammer thump, a soft lowpass and tape saturation. Playback adds tape wow plus a faint bed of hiss and vinyl crackle.
- **The notes** are lazy, swung eighths. The arpeggio takes a random walk over the current chord's tones, mostly stepwise, with occasional leaps, repeats, passing tones from the scale, two-note dyads, and rests. It rests more when the field is sparse and anchors on the bar line.
- **The tempo** is the field's own pulse: how often each device's signal crosses its own average, about 20 s averaged across devices. That rate is folded by octaves (halving or doubling) into a relaxed 44–104 BPM, always choosing the fold closest to the current tempo, and glides there over ~12 s.
- **The space** grows with the crowd. More devices bring more delay (on a dotted eighth of the tempo) and more room reverb, kept slight.

## The duo: Aether + Bellweathered

This project also contains **Bellweathered** (`Bellweather/`), an iPhone port of the web version (`samuelling/Bell-weathered`): the live sky (Open-Meteo weather where you are, or a simulated sky of drifting weather regimes) plus the sun and moon, played as a six-layer drone with slow pitch drift, wind and gusts, rain or snow hiss, an hourly bell on the solar hour, and seven Airports-style melody loops (glass bell, string or kalimba).

Open each app on its own iPhone, near each other, and they find each other automatically (MultipeerConnectivity over Bluetooth or peer-to-peer Wi-Fi, so no router is needed). The work is divided by timescale:

| | Bellweathered (sky, hours) | Aether (radio room, seconds) |
|---|---|---|
| Leads | **Harmony**: root and scale | **Time**: tempo and the chord timeline |
| Follows | Aether's tempo (sets its echo); Aether's chord changes steer its drone; a crowded room livens its melody | Bellweathered's key and scale; daylight in its sky opens Aether's pad a little |

Both follow toggles live in each app's Settings › Duo. If the phones lose each other, each carries on solo, and they re-sync when they meet again. Messages are tiny and arrive in tens of milliseconds, well inside what ambient tempos and multi-second glides need. Tight beat-phase lock (Ableton Link) is the natural next step if a beat-locked arpeggio between the two is ever wanted.

To run Bellweathered, pick the **Bellweather** scheme in Xcode's toolbar (next to the device menu), set its Team the same way, and press ▶. It asks for your approximate location (to hear your weather and sun) and for local-network access (to find Aether).

## Install on your iPhone

Needs a Mac with Xcode 16 or newer (Xcode 26 for an iPhone on iOS 26). A free Apple ID is enough.

1. Open `Aether.xcodeproj`.
2. Click the blue **Aether** project icon → **Signing & Capabilities** → **Team**: add/select your Apple ID. If the bundle ID is rejected, change `com.samuelling.aether` to something unique.
3. Connect the iPhone by cable and tap **Trust**. Enable **Settings › Privacy & Security › Developer Mode** (phone restarts).
4. Choose your iPhone in Xcode's device menu and press **▶ Run**.
5. First launch only: **Settings › General › VPN & Device Management** → trust your developer profile.
6. Allow Bluetooth when asked, then tap **Listen**. Headphones recommended.

Free-account installs expire after 7 days — press Run again to refresh.

## Notes and limits

- iOS only delivers continuous RSSI updates while the app is in the foreground, so the screen stays awake while playing.
- iOS deliberately hides Wi-Fi signal strength from apps; Bluetooth LE is the closest open window onto the same band.
- Many devices (especially Apple ones) rotate their Bluetooth address every ~15 minutes for privacy, so an emitter can vanish and reappear with a different phrase. That's the field reshuffling itself.
- AirPlay works: use the AirPlay button on Aether's screen or Control Center. Keep the app in front so scanning stays live.
- Settings: 12 scales/modes, root note, **Octave** transpose (−2…+2), voice count (1–32), **Reach** (the faintest dBm that still sings), and how often the pad chord changes.
- **Response** (Snap ⟷ Drift, log-scaled) scales the expressive smoothing between the radio and the sound: ≈ 2 s at Drift (default), ≈ 0.2 s at Snap, where the floor is mostly how often devices advertise. Toward Snap, notes swell in ~70 ms, a cupped hand silences what's ringing, and a sudden approach to a device (≈ +8 dB) pulls its next note forward so it sings at once. The per-device mean and jitter keep fixed time constants at every setting, so wow and tempo stay meaningful.

## Code map

- `FieldModel.swift` — CoreBluetooth scanning, per-emitter smoothing/jitter, phrase + loop generation, voice allocation, chord progression (30 Hz control loop)
- `DroneDSP.swift` — realtime synth: a shared pool of 64 note voices (table-lookup sine + chorused twin + soft overtones, slow envelope, tape wow; least-recently-used reuse) and a 4-voice filtered-saw pad bed; lock-free parameter block
- `DroneEngine.swift` — AVAudioEngine graph (delay → cathedral reverb, an octave-up shimmer hall, and the arpeggio's own delay → hall bus), session handling, fade in/out
- `RadarView.swift` — polar map of the field
- `Shared/DuoLink.swift` — the duo protocol both apps compile in
- `Bellweather/` — Bellweathered: `SkyModel` (weather, sun/moon, mappings, loops, duo), `BellDSP` (drone, wind, rain/snow, bell, melody voices), `BellEngine` (delay → reverb graph), `SkyView` (the animated sky), `Sky` (astronomy, Open-Meteo, simulated sky)
- `ArpDSP.swift` — synthesized dusty-upright multisample, stochastic arpeggiator, tape wow, hiss and crackle
- `ContentView.swift` — app entry, main screen, settings sheet, AirPlay button
- `Assets.xcassets` — app icons: periodic-table element tiles (Ae 119 [2402], Bw 120 [1013]), generated by `AppStore/make_icons.py`
