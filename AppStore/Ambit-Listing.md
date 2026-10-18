# App Store submission: Ambit (listed as "Ambit: Quartet")

Everything App Store Connect asks for before the first submission, in the order its pages ask for it. Character counts are checked against Apple's limits. Items marked **⟶ you** need Sam's decision.

App Store Connect › Apps › **Ambit: Quartet** (bundle `com.samuelling.ambit`, SKU `ambit-ios`, Apple ID 6823966066).

## 1. App Information

| Field | Value |
|---|---|
| Name | Ambit: Quartet ("Ambit" was taken) · 14/30 |
| Subtitle | Hear the invisible around you · 29/30 |
| Category | Music · secondary: Entertainment |
| Content rights | **Yes**, it accesses third-party content, and has the rights: Open-Meteo weather (CC BY 4.0, credited in the app and listing) and CelesTrak's public satellite catalog |
| Age rating | Answer **None / No** to every question → **4+** (no web browsing, user content, messaging, ads, gambling, medical claims) |
| Privacy Policy URL | https://samuelling.github.io/Aether/docs/ambit/privacy.html |
| Copyright | **⟶ you**: e.g. `2026 Sam Ling` |
| EU Digital Services Act | **⟶ you**: trader or non-trader (see below) |

## 2. Pricing and Availability

- Price: **Free**
- Availability: all countries **except China mainland**, which requires an ICP filing number for new apps that an individual can't easily get.

## 3. App Privacy

- **Data Collected → Location › Coarse Location**: purpose **App Functionality**, linked to the user **No**, used for tracking **No**.
  (Rounded coordinates go to Open-Meteo to fetch the weather. The same answer Bellweathered uses.)
- Nothing else is collected: Bluetooth, the satellite positions and the phone's traffic counters never leave the phone, and the optional traffic log is a file only the user can see.

## 4. Version 1.0 (App Store tab)

**Screenshots**: iPhone 6.9" display, 1320 × 2868, 3 to 10 images (iPad not needed: Ambit is iPhone-only). Made from ordinary phone screenshots with `python3 AppStore/make_ambit_screenshots.py RAW_DIR OUT_DIR`, which captions each one:

1. The mix pad, playing — *Hear the invisible around you*
2. Orbitakt's sky dome — *The satellites overhead*
3. Bellweathered's sky — *The weather, as a deep drone*
4. Aether's radar with several voices — *The radio waves in the room*
5. Leitmotif's ledger mid-song — *Your phone's own traffic, on piano*
6. "What is this?" — *Everything stays on your iPhone*

**Promotional text** (163/170)

Four instruments play the invisible world around you: the radio waves in the room, the weather overhead, your phone's own traffic and the satellites passing above.

**Description** (2036/4000)

```
Ambit plays the invisible world around you as music.

Four instruments each listen to a different layer of your surroundings, from the radio waves in your room to the satellites passing overhead, and play together in one key and one tempo. A joystick in the middle mixes them: all four at the centre, just one at the edge.

AETHER: THE RADIO ROOM
Every phone, watch, earbud and speaker nearby broadcasts a Bluetooth signal several times a second. Each one becomes a voice with its own short melody on its own slow loop, in the spirit of Brian Eno's Music for Airports. Walk toward a device and it sings louder; turn around and the chord reshapes. Aether sets the tempo and the chord changes for the whole ensemble.

BELLWEATHERED: THE WEATHER
The live weather where you are, as a deep, pure bass drone. Falling pressure brings up the sub-octave, warmth and daylight open it up, cloud rounds it off, and wind makes it beat and breathe. Rain adds a hiss, snow a hush, and a bell rings on the solar hour. The sky sets the key.

LEITMOTIF: YOUR PHONE
Your iPhone is always talking. Leitmotif hears the rhythm of its own data traffic, never the content, and sings each habit as a short piano motif, so streaming, messaging and scrolling each get a tune of their own.

ORBITAKT: THE SATELLITES
Thousands of satellites cross your sky. A radar beam sweeps round from north, and every satellite near the zenith plays a drum as the beam passes it: navigation satellites a deep kick, Starlink metallic hats, the geostationary belt a gated hat, all through a dub echo. The ISS brings a gong when it passes over.

KEEPS PLAYING
Ambit plays in the background and on the lock screen, alongside your other audio. Tap "What is this?" in the app for the whole story.

PRIVATE BY DESIGN
No accounts, ads, analytics or tracking. Everything is computed on your iPhone. Your approximate location is used only to fetch the weather and to place the satellites in your sky.

Weather data by Open-Meteo.com. Satellite data from CelesTrak. Headphones recommended.
```

**Keywords** (95/100): `ambient,generative,drone,weather,satellite,bluetooth,eno,sleep,focus,soundscape,synth,piano,dub`

**Support URL**: https://samuelling.github.io/Aether/docs/ambit/index.html#support
**Marketing URL** (optional): https://samuelling.github.io/Aether/docs/ambit/index.html

**Build**: upload build **1.0 (2)** first. Build 1 on TestFlight predates the pure-sine Bellweathered drone; the project is already bumped to 2.

**App Review Information**: sign-in not required. Contact: Sam Ling, samuelling@me.com, the phone on the developer account. Notes (1009/4000):

```
Ambit is an ambient music app with four instruments. No account or sign-in. Tap "Play" on the main screen to start; it makes no sound until then. Drag the puck on the round pad to change the mix (centre = all four, edge = one); tap an instrument to open its own page.

Permissions (both optional; without them it plays a quieter room and a simulated sky):
- Bluetooth: Aether reads only the signal strength of nearby Bluetooth LE advertisements, on device. It never connects to devices; nothing is stored or sent.
- Approximate location (when in use): rounded coordinates are sent to Open-Meteo for the local weather; satellites from CelesTrak's public catalog are placed in the sky on device.

Background audio: the music keeps playing in other apps and on the lock screen. Leitmotif sonifies the phone's own aggregate network byte and packet counters (no content, no destinations, no VPN or network extension).

Bellweathered's Settings has a "Simulated" weather switch to hear different conditions quickly.
```

**Version release**: **⟶ you**: release automatically when approved, or manually.

## 5. Things App Store Connect checks that are already done

- Export compliance: `ITSAppUsesNonExemptEncryption = NO` is in the build, so no questions.
- App icon (1024 × 1024, no transparency) is in the build.
- Usage descriptions for Bluetooth and location are in the build; background audio is declared and used for audible music.
- Privacy policy and support pages are live on GitHub Pages.

## Decisions for Sam

- **EU trader status.** If you declare yourself a *trader*, your address, phone and email are shown on the EU App Store. A hobbyist publishing free apps with no business behind them would typically choose *non-trader*, but it's your call.
- **Copyright line** (the name as it should appear).
- **Release**: automatic or manual after approval.

## Aether Wave and Bellweathered

Ambit is the app being published. The two older App Store Connect records (Aether Wave, Bellweathered) stay in "Prepare for Submission" and are never submitted, so there's no overlap for App Review to flag. They can be left as they are; an unsubmitted record isn't visible to anyone.
