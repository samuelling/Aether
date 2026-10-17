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

## Tempo

Aether keeps time for the duo, and for Leitmotif when it listens in. The tempo is the field's own pulse: how often each device's signal crosses its own average, about 20 s averaged across devices. That rate is folded by octaves (halving or doubling) into a relaxed 44–104 BPM, always choosing the fold closest to the current tempo, and glides there over ~12 s. Settings › Tempo shows it.

(The optional piano arpeggio that used to live here has moved: its dusty upright is now Leitmotif's voice.)

## The duo: Aether + Bellweathered

This project also contains **Bellweathered** (`Bellweather/`), an iPhone port of the web version (`samuelling/Bell-weathered`): the live sky (Open-Meteo weather where you are, or a simulated sky of drifting weather regimes) plus the sun and moon, played as a six-layer drone with slow pitch drift, wind and gusts, rain or snow hiss, an hourly bell on the solar hour, and seven Airports-style melody loops (glass bell, string or kalimba).

Open each app on its own iPhone, near each other, and they find each other automatically (MultipeerConnectivity over Bluetooth or peer-to-peer Wi-Fi, so no router is needed). The work is divided by timescale:

| | Bellweathered (sky, hours) | Aether (radio room, seconds) |
|---|---|---|
| Leads | **Harmony**: root and scale | **Time**: tempo and the chord timeline |
| Follows | Aether's tempo (sets its echo); Aether's chord changes steer its drone; a crowded room livens its melody | Bellweathered's key and scale; daylight in its sky opens Aether's pad a little |

A third app, **[Leitmotif](https://github.com/samuelling/Leitmotif)**, can join as a listener: it plays your own phone's data traffic as a solo line over the duo, on the dusty upright piano that used to be Aether's arpeggio, taking key and scale from Bellweathered and tempo and chords from Aether. Listeners never send and never invite. Both leads invite them into their sessions, so the duo pairs exactly as before, and each lead's Settings › Duo shows who is "Listening in".

A fourth, **[Orbitakt](https://github.com/samuelling/Orbitakt)**, listens in the same way: the satellites overhead as Euclidean percussion, taking key and scale from Bellweathered and tempo from Aether.

Both follow toggles live in each app's Settings › Duo. If the phones lose each other, each carries on solo, and they re-sync when they meet again. Messages are tiny and arrive in tens of milliseconds, well inside what ambient tempos and multi-second glides need. Tight beat-phase lock (Ableton Link) is the natural next step if beat-locked parts across the phones are ever wanted.

To run Bellweathered, pick the **Bellweather** scheme in Xcode's toolbar (next to the device menu), set its Team the same way, and press ▶. It asks for your approximate location (to hear your weather and sun) and for local-network access (to find Aether).

## Ambit: all four in one app

**Ambit** (`Ambit/`) plays Aether, Bellweathered, [Leitmotif](https://github.com/samuelling/Leitmotif) and [Orbitakt](https://github.com/samuelling/Orbitakt) together on one iPhone, in one key and tempo, and keeps playing in your pocket.

- **One engine, one mix.** Each instrument wires its own synth and effects into its own bus on a single AVAudioEngine, then a peak limiter. A stopped instrument closes a render gate and costs almost nothing.
- **In sync, in process.** The four models are the apps' own, and they talk through an in-process `DuoLink` with the same API as the multi-phone one (`Ambit/Core/DuoLink.swift`). Bellweathered's sky leads the key and scale; Aether's radio room leads the tempo and chords; Leitmotif and Orbitakt follow. Nothing can drop the link, so they stay locked together in the background too.
- **The mix pad.** The home screen is a joystick with the instruments around it: Orbitakt above (space), Bellweathered below (land), Leitmotif to the right, Aether to the left. Push the puck toward one and it swells about 3 dB, the one opposite fades out and the two beside hold, smoothly in between. Double-tap the pad to centre it. Under it, each instrument has a level and an on/off switch.
- **Pages.** Tap an instrument to open its own screen (radar, sky, ledger, dome) with all its settings. The page slides in toward that instrument, and the back button slides it back.
- **In the background.** Ambit uses the audio background mode and mixes with other audio. Leitmotif, Bellweathered and Orbitakt carry on live. iOS stops delivering Bluetooth advertisements to apps out of view, so Aether *holds the last room it heard*: its emitters keep singing their loops, tempo and air hold, nobody ages out, and its chord timeline keeps turning so the others still change chords with it. Back in front, it rescans and goes live again. Settings › Keep the screen on is there for when you want a live room.

Two builds, like Leitmotif's:

| | **Ambit** (target `Ambit`) | **Ambit Name** (target `AmbitName`) |
|---|---|---|
| Leitmotif hears | the gait of your traffic (byte counters) | the names your phone looks up (on-device DNS tunnel, `AmbitNameTunnel`) |
| Bundle ID | `com.samuelling.ambit` | `com.samuelling.ambit.name` (+ `.tunnel`) |
| App Store | fine | personal: run from Xcode or internal TestFlight (guideline 5.4) |
| Icon | Ab 124 [4] | An 125 [53] |

To run one, pick the **Ambit** or **AmbitName** scheme in Xcode's toolbar, set the Team (for Ambit Name, on both AmbitName and AmbitNameTunnel, each with Network Extensions → Packet Tunnel), and press ▶. It asks for Bluetooth (Aether), approximate location (Bellweathered's weather and Orbitakt's sky) and, for Ambit Name, to add a VPN configuration.

The instruments' code in `Ambit/` is a fork of each app's, adapted to the shared engine (`init(audio:)`, gated render blocks, no per-app session or multipeer). Fixes to a synth or model need copying across by hand, the same way the suite's `DuoLink` copies are kept in step.

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
- `DroneEngine.swift` — AVAudioEngine graph (delay → cathedral reverb, plus an octave-up shimmer hall), session handling, fade in/out
- `RadarView.swift` — polar map of the field
- `Shared/DuoLink.swift` — the duo protocol both apps compile in (Leitmotif keeps an identical copy in its `Duo/` folder and Orbitakt in its `Shared/` folder; change all three together)
- `Bellweather/` — Bellweathered: `SkyModel` (weather, sun/moon, mappings, loops, duo), `BellDSP` (drone, wind, rain/snow, bell, melody voices), `BellEngine` (delay → reverb graph), `SkyView` (the animated sky), `Sky` (astronomy, Open-Meteo, simulated sky)
- `ContentView.swift` — app entry, main screen, settings sheet, AirPlay button
- `Assets.xcassets` — app icons: periodic-table element tiles (Ae 119 [2402], Bw 120 [1013]), generated by `AppStore/make_icons.py`
- `Ambit/Core/` — Ambit: `AmbitApp` (the mix pad, rows, page transitions), `Ensemble` (the four models, transport, the pad's bias and levels, background), `AmbitAudio` (the shared engine, layer buses, limiter, render gates), `DuoLink` (the in-process link)
- `Ambit/Aether`, `Bell`, `Motif`, `Orbitakt`, `Leitmotif`, `LeitmotifName`, `NameShared`, `NameTunnel` — the instruments' forks for Ambit; icons in `Ambit/AppIcon*`, generated by `AppStore/make_ambit_icons.py`
