# Aether

An iPhone instrument that listens to the Bluetooth LE radio field around you and plays it as ambient, melodic pads, in the spirit of Brian Eno's *Music for Airports*.

Every advertising device in range (phones, watches, earbuds, TVs, the neighbors' gadgets) reports a signal strength (RSSI) several times a second on the 2.4 GHz band. Aether gives each one its own tape loop: a short melodic phrase of 1–3 notes, repeating on a loop length between 14 and 30 seconds. Because no two loops share a period, the phrases drift in and out of alignment and the melody keeps recombining. Underneath, a soft pad chord drifts slowly through a progression.

## How the radio becomes music

| Radio | Music |
|---|---|
| Each emitter's identity (hashed) | Its phrase, loop length, stereo position and radar bearing, fixed for as long as it's around |
| Signal strength | How loud and bright its notes are. Faint devices sing only the first note of their phrase; move closer and the whole phrase unfolds |
| Jitter (dB wobble around its mean) | Tape wow: the notes' pitch bends gently, like a warped cassette |
| Strongest N emitters | Get voices (sticky, so they don't flap between near-equals) |
| How many emitters are around | Fullness of the pad chord |
| Whole-field motion vs. its baseline ("air") | The pad opens up and the octave-up shimmer halo swells as you move |

The signal chain is soft sine-based tones with slow swells and ~20 s releases, a long 1.35 s delay, a cathedral reverb, and a parallel octave-up hall for shimmer. There are no drones and no bells.

Moving matters because at 2.4 GHz the wavelength is ~12.5 cm. Reflections off walls interfere, so the field is full of nulls a few centimeters apart, and your body (mostly salt water) casts a radio shadow. Turning around or walking through a doorway changes who's singing.

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
- Settings: scale, root note, voice count (1–8), **Reach** (the faintest dBm that still sings), and how often the pad chord changes.

## Code map

- `FieldModel.swift` — CoreBluetooth scanning, per-emitter smoothing/jitter, phrase + loop generation, voice allocation, chord progression (30 Hz control loop)
- `DroneDSP.swift` — realtime synth: 24 note voices (sine + chorused twin + soft overtones, slow envelope, tape wow) and a 4-voice filtered-saw pad bed; lock-free parameter block
- `DroneEngine.swift` — AVAudioEngine graph (delay → cathedral reverb, plus octave-up shimmer hall), session handling, fade in/out
- `RadarView.swift` — polar map of the field
- `ContentView.swift` — app entry, main screen, settings sheet
- `Assets.xcassets` — app icon (three tapered waves, rendered at 1024 px)
