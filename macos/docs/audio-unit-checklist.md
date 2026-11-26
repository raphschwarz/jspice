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

## 6. On the real-time thread

The plugin's render thread takes no lock the window can hold and rebuilds nothing: a knob, a switch or a preset is
prepared in the background and swapped in at the next buffer, a few milliseconds later. These checks are best done at
the smallest buffer the host offers (Logic: **Settings ▸ Audio ▸ I/O Buffer Size**, 32 or 64 samples), with the CPU
meter open. A dropout is a click or a gap; the CPU meter's overload marker (Logic: a red "System Overload" alert) counts too.

1. **Automation while playing.** At 64 samples, play the guitar loop through **Fuzz Face on a guitar riff**, draw a
   fast automation ramp for **FUZZ** (up and down several times a second) and play it back. The sound follows within
   a few milliseconds, with no clicks, dropouts or overloads. Do the same moving the slider in the plug-in window by
   hand while playing.
2. **Echo through knob moves.** Choose **PT2399 echo**, play a short phrase and, while the repeats are still sounding,
   move **TIME** and **REPEATS** in the window: the repeats carry on (changed) rather than being cut off.
3. **A switch while an echo rings.** Choose **3PDT true bypass** and flip **SW1** while playing: the sound switches
   after a short moment, with no dropout and no thump. Then, on an echo or reverb with a switch (export one from
   JSpice, say **MN3011 multi-tap echo** with a bypass or mode switch added), play a phrase and flip the switch while
   the repeats ring: the repeats carry on through the switch. Expected and acceptable: the tail resumes from where it
   was when the switch was asked for, one build earlier (some tens of milliseconds, longer for big circuits), so
   there is a small skip in the repeats, and for that moment the echo itself is silent (the dry sound carries on).
   What would be a fault: the tail cut off entirely, a click to silence, or a thump.
4. **Preset change while playing.** At 64 samples, step through the circuits in the Circuit menu (and in the host's
   own preset menu) while the transport runs. The old circuit keeps playing until the new one is ready (heavier ones
   take up to a second or so to settle), then the new one takes over: no gap of silence, no overload, the window
   stays responsive.
5. **Instrument notes through knob moves.** On the instrument with **Synth voice: VCO, VCF, VCA**, hold a note and move
   **FRES**: the note keeps sounding, with no retrigger. Play notes while automating **FRES**.
6. **A circuit too heavy for the buffer.** At 64 (or 32) samples, put **Bode frequency shifter** or **LM13700 filter**
   on several tracks until the CPU meter is near full. Within about a second the plug-in window shows an orange
   message ("Running 1 step per sample to keep up…", or "Too heavy for this buffer…") and the sound carries on, a
   little less precise, instead of dropping out. There may be one short jump in the sound when it changes down. Raise
   the buffer to 256 and choose the circuit again: the message goes.
7. **Sample rate and buffer changes.** Change the project's sample rate and the buffer size while the plug-in is
   inserted: playback resumes with the circuit at the right pitch, without a crash.
8. **Nothing logged.** In **Console.app**, filtered on `JSpiceAudioUnit`, none of the above prints anything while
   playing.

## What to report

- Each step that failed: its number, what happened, and the host and its version.
- The CPU figures from step 2.7, and for step 6 how many instances it took before the message appeared.
- Anything printed under **JSpice** in **Console.app** while it misbehaved (filter on `JSpiceAudioUnit`).
