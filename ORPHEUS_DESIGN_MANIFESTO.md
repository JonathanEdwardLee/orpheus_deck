# ORPHEUS DECK — CORE DESIGN MANIFESTO

Orpheus Deck is not a modern DAW.

It is a digital four-track cassette recorder inspired by old Tascam/PortaStudio-style recording, cheap cassette overdubbing, hardware limitations, and the feeling of quickly capturing a song idea before it disappears.

The app should behave like a simple musical device, not a full editing workstation.

---

## PRIMARY PURPOSE

The main purpose is fast capture.

A musician should be able to open the app, start a project, arm a track, press record, and capture an idea sent from the muses with minimal friction.

The app should feel immediate, physical, and slightly magical — like turning on an old machine and catching a song before it vanishes.

---

## SECONDARY PURPOSE

The app is also a creative limitation tool.

It intentionally limits the user to four tracks, like an old cassette four-track recorder. The limitation is not a weakness. It is the point.

The app should encourage commitment, accidents, bounce-down thinking, lo-fi layering, and performance-based recording instead of endless digital editing.

---

## CORE RULES

**1. This is a FOUR TRACK RECORDER, not a multitrack DAW.**
- Always use "four-track" language.
- Avoid DAW terminology unless necessary.
- Do not add unlimited tracks.
- Do not add complex timeline editing.
- Do not turn it into a full production suite.

**2. The app should preserve analog-style limitations.**
- Four tracks maximum.
- Fixed cassette-side recording length.
- Minimal editing.
- No complex clip grid.
- No piano roll.
- No plugins.
- No unlimited undo.
- No infinite timeline.

**3. Default max tape length should be 15 minutes.**
- Treat this like one side of a cassette.
- Playback should stop automatically at the end of the tape.
- Recording should stop automatically at the end of the tape.
- The UI should show the user where they are on the tape.

**4. Add a bottom tape reel / timeline control.**
- This is not a DAW timeline.
- It should be a simple cassette position reel.
- The user can drag/scrub to choose where playback or recording starts.
- It does not need to show individual audio clips.
- It represents tape position, not digital regions.
- It should feel like moving to a point on tape.

**5. Overdubbing with headphones should be recommended but not required.**
- Clean overdub mode should exist for users wearing headphones.
- Lo-fi bleed mode should also exist.
- In lo-fi bleed mode, the phone speaker can play existing tracks while the microphone records the new layer.
- This intentionally captures room noise, speaker bleed, distortion, and previous layers.
- This is not a bug. It is a creative mode inspired by bouncing between cassette players.

**6. The app should support two overdub philosophies:**

### CLEAN OVERDUB
- Recommended with headphones.
- Existing tracks play to headphones.
- New track records mostly only the live performance.
- This is closer to normal four-track overdubbing.

### LO-FI BLEED OVERDUB
- Headphones not required.
- Existing tracks play through the phone speaker.
- Microphone records the new performance plus speaker playback and room sound.
- Each layer can get dirtier, more compressed, noisy, and haunted.
- This is intentional and should be treated as a feature.

**7. Editing should be minimal.**

Preferred editing:
- clear track
- re-record track
- move tape position
- maybe trim project start/end later
- maybe bounce tracks later

Avoid:
- waveform region cutting
- splice editing
- clip grids
- complex copy/paste
- infinite non-destructive editing

**8. The interface should feel like hardware.**
- OLED monochrome
- cassette machine
- chunky transport buttons
- track arm buttons
- simple mixer controls
- reel/tape position
- project behaves like a tape

**9. The app should be fast and low-friction.**

The ideal flow:
- Open app
- Choose Resume or New Tape
- Arm track
- Press Record
- Capture idea
- Stop
- Play back
- Overdub if inspired
- Export/share if worth keeping

**10. The app should protect the artist from overthinking.**

The design should push:
- record now
- make decisions
- accept happy accidents
- keep moving
- finish ideas
- embrace flaws

---

## PRODUCT DESCRIPTION

Orpheus Deck is a Junkfeathers Tech four-track cassette recorder for Android.

It captures song ideas quickly with the charm and limitations of old tape machines. You get four tracks, a fixed tape length, a simple transport, cassette-style overdubbing, and optional lo-fi bleed recording where each layer can pick up the room, the speaker, and the ghosts of previous takes.

It is not designed to replace a DAW. It is designed to catch ideas before they disappear and turn limitations into character.

---

## BUILDING PRINCIPLE FOR AI ASSISTANTS

When modifying this app, do not automatically modernize it into a DAW.

Before adding any feature, ask:
> "Would this belong on a simple four-track cassette recorder?"

If not, avoid it or hide it behind an advanced/export utility.

The soul of the app is:
**fast capture, four-track limits, cassette personality, lo-fi accidents, and musician-friendly simplicity.**

---

## ANTI-FEATURE-CREEP RULES

Do NOT automatically add:
- unlimited tracks
- piano roll
- plugin chains
- advanced DAW timelines
- clip launching
- automation lanes
- complex non-destructive editing
- desktop-style arrangement view

The app should remain:
- immediate
- constrained
- tape-like
- musician-focused
- low-friction
