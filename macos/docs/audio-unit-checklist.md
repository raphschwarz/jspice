# Checking the JSpice Audio Unit in a music app

CI builds the Audio Unit and Apple's `auval` passes it, but `auval` runs no real host: this list checks what only
Logic Pro, GarageBand (or another Audio Unit host such as Ableton Live or Reaper) can show. It takes about
twenty minutes. Note anything that fails, with the step number, and what you saw.

## 1. Install

1. Download **JSpice-macOS.zip** from the latest green run of the macos workflow, unzip it, and move **JSpice.app**
   to **/Applications** (the system only looks for Audio Units in apps it knows).
2. Clear the download quarantine, which would otherwise stop the extension loading:
   `xattr -dr com.apple.quarantine /Applications/JSpice.app`
3. Open JSpice once, then quit it. This registers the extension.
4. In Terminal, check that macOS sees both components:
   ```
   pluginkit -m -v -i org.knowm.jspice.mac.audiounit
   auval -a | grep JSpc
   ```
   Expect one plug-in, and two lines: `aufx jsfx JSpc - JSpice: Circuit Effect` and
   `aumu jsin JSpc - JSpice: Circuit Instrument`.
5. Optional, the same check CI runs: `auval -v aufx jsfx JSpc` and `auval -v aumu jsin JSpc` both end with
   **AU VALIDATION SUCCEEDED**.

## 2. The effect

1. Logic: **Logic Pro ▸ Settings ▸ Plug-in Manager**, select **JSpice**, **Reset & Rescan Selection**. Both units
   should show as successfully validated. (GarageBand rescans by itself when it starts.)
2. Make an audio track with a guitar or drum loop. In an empty effect slot choose **Audio Units ▸ JSpice ▸
   JSpice: Circuit Effect**.
3. The plug-in window opens with a **Circuit** menu, the circuit's knobs as sliders, and the export hint at the
   bottom. Its first circuit is **Fuzz Face on a guitar riff**.
4. Play: the loop comes out fuzzed. Move **FUZZ** and **VOLUME**: the sound follows within a fraction of a second,
   without clicks or dropouts.
5. Choose **Diode-clipper overdrive**, then **Single-ended tube amp**, then **LM13700 filter** from the Circuit menu
   while playing. Each changes the sound; the sliders change to that circuit's knobs.
6. The same circuits appear in the host's own preset menu (Logic: the **Factory** presets in the plug-in header).
7. Watch the CPU meter (Logic: **Window ▸ Open CPU Meter**). Note roughly how much one instance takes at
   48 kHz with a 256-sample buffer, and whether the tube amp or LM13700 filter can overload it.
8. Automation: record-arm automation for **FUZZ**, move it while playing, then play back: the slider moves on its own
   and the sound follows.
9. Bypass the plug-in and enable it again: no stuck note, no lasting silence.

## 3. The instrument

1. Make a software instrument track and choose **AU Instruments ▸ JSpice ▸ JSpice: Circuit Instrument**.
2. Choose **Mono synth: VCO, envelope and VCA** from the Circuit menu. Play notes on a MIDI keyboard or Logic's Musical Typing (⌘K): each note
   sounds at its pitch and stops when released.
3. Hold one key, press and release a second: the pitch goes to the second note and back to the first (last-note
   priority, as on a monophonic synth).
4. Choose **Synth voice: VCO, VCF, VCA** and **Keyboard VCO (1 V/octave)**, and play again.
5. Play fast repeated notes and a long glissando: no hung notes. Stop the transport while holding a key: the note
   ends (all notes off).

## 4. Your own circuit

1. In JSpice, open an example (say **CMOS fuzz**), change a value, and choose **File ▸ Export as Audio Unit…**. Give
   it a name. It is saved in `~/Music/JSpice/Audio Units`.
2. In the plug-in window, press the reload button (↻) next to the Circuit menu: your circuit appears at the end
   of the list. Choose it and play.
3. Export a circuit with no speaker: JSpice says it can't be played in a music app and why.

## 5. Sessions

1. Set a circuit and some knob positions, save the project, and quit the host.
2. Reopen the project: the same circuit plays, with the same knob positions.
3. Delete the circuit's file from `~/Music/JSpice/Audio Units` and reopen the project again: it still plays, since
   the project keeps the whole circuit.
4. Change the project's sample rate (44.1 kHz ↔ 48 kHz) and play: the pitch of the instrument and the character of
   the effect stay the same.

## What to report

- Each step that failed: its number, what happened, and the host and its version.
- The CPU figures from step 2.7.
- Anything printed under **JSpice** in **Console.app** while it misbehaved (filter on `JSpiceAudioUnit`).
