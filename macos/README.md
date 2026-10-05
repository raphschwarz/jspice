# JSpice for Mac

A native macOS circuit simulator in the spirit of iCircuit and the Falstad applet: draw a circuit and watch it run live, with voltages shown as colour and current as moving dots.

![LED and switch](docs/led.png)

## Features

- **Fast, keyboard-first editing.** Every part has a shortcut (a letter for the common ones, ⇧ and a letter for the rest; they are shown in the library and in Help ▸ Keyboard Shortcuts, ⌘/). ⌘K or / opens a palette: type a part's name, its category or a real part it models ("TL072", "LM13700", "vactrol") and press Return. While placing, a ghost of the part follows the pointer and a pill says what you are placing. Arrow keys nudge the selection (⇧ for five units), ⌘D duplicates it, Tab steps through the parts, and the library can be searched.
- **Draw circuits directly.** Pick a part in the library (or press its key: `R` resistor, `C` capacitor, `W` wire, …), then click to place it or drag to set its length and direction. Parts connect where their ends meet, and a part dropped onto the middle of a wire joins it with a T-junction (wires that merely cross stay apart). Wires stretch when you move the parts they connect.
- **Live simulation.** The circuit simulates while you draw. Voltages are coloured (green positive, red negative, grey at 0 V), current flows as dots, LEDs and lamps glow, and memristors show their internal state.
- **Real time when possible.** Circuits that change slowly enough to watch run in real time (a capacitor charging over a second, a 1 Hz memristor loop). Faster ones run in slow motion automatically, for example a 100 Hz filter at 5 ms per second, and the status bar says so. If a circuit is too heavy to keep up, it runs as fast as it can and the status bar shows how far behind it is. You can also set the speed yourself.
- **Interact while it runs.** Click switches, hold push buttons, scroll over a potentiometer to turn it, and drag sliders in the inspector to change values live.
- **Hear it.** Put a speaker across an output and press **Sound** in the toolbar: the circuit runs in real time, one simulation step per audio sample, on a thread of its own, and you hear it through the Mac's output (with a DC blocker and a soft limit, so a stuck rail is silent and nothing clips harshly). Turn a potentiometer or flip a switch while it plays. The speaker's **full scale** sets the voltage that plays at full volume.
- **Play it.** The **Keyboard Pitch** source puts out 1 V per octave (0 V at C2) and the **Keyboard Gate** source a gate while a key is held. With sound on, play them from the Mac's keyboard (A W S E D F T G Y H U J K O L P ; as in GarageBand; Z and X change octave) or from any MIDI keyboard (notes and pitch bend). The newest key sounds, and the pitch stays on the last note after release; give the pitch some **glide** for portamento. A **step sequencer** (in the inspector when the circuit has a keyboard source) plays them by itself: up to 32 steps of notes or rests at a sixteenth note each, with tempo and gate length; it keeps time with the circuit, so it is exact with sound on and in automated simulations. The **Keyboard VCO** example is a real 1 V/octave oscillator (a PNP exponential converter and an LM13700 triangle core), and **Mono synth** plays its square wave through an LM13700 VCA opened by an attack–release envelope (the gate charges it through a DG411 switch).
- **Front panel.** Below the schematic, the circuit's potentiometers, switches and push buttons appear as hardware controls on a faceplate, like a plugin's interface for testing an audio circuit: knobs to drag (double-click to centre), bat toggles to flip, buttons to hold, LEDs as panel lamps, and a level meter for the speaker that turns red when the sound clips. Double-click a label to rename the part. Toggle it with **Panel** in the toolbar.
- **Scopes** for any part's voltage, current, power or resistance over time, or its current against its voltage (an I–V curve, such as a memristor's pinched hysteresis loop).
- **Library of parts:** wire, ground, net label, resistor, potentiometer, lamp, capacitor, inductor, DC/AC/square-wave voltage sources, current source, switch, push button, diode, Zener diode, LED, NPN and PNP transistors, NMOS and PMOS transistors, N-JFET, op-amp, OTA, analog multiplier, 555 timer, Schmitt inverter, analog switch, bucket-brigade delay line, vactrol, memristor, voltmeter probe, ammeter, speaker, keyboard pitch and gate, white noise. Transistors, op-amps, OTAs, chips and potentiometers can be flipped as well as rotated.
- **Synth parts with real-part behaviour.** One op-amp symbol, one OTA symbol and so on, with the specific part chosen in the inspector's **Model** menu:
  - Op-amp: Ideal, TL072, LM358, NE5532, LM741 (open-loop gain, output swing, slew rate, gain-bandwidth and input offset, so an LM358 visibly slews where a TL072 does not).
  - OTA: LM13700 or CA3080 (output current I_abc·tanh(V_in / 2V_T), bias pin one or two junctions above V−, output clamps below the supply).
  - Multiplier: AD633 (out = x·y / 10 V, softly limited), for ring modulators and VCAs.
  - Bucket-brigade delay line: MN3207, MN3008, MN3005 (delay = stages / 2·clock, the clock swept by a control voltage), for chorus, flanger and echo.
  - Vactrol: VTL5C3, NSL-32 (an LED and an LDR whose resistance follows the light with separate attack and decay times), for lowpass gates, compressors and opto tremolo.
  - Diodes: 1N4148, 1N4001, 1N34A (germanium), BAT41 (Schottky). Transistors: 2N3904, BC547C, 2N5088, BC108, 2N3906, AC128 (germanium). Potentiometers: linear or audio taper.
  - 555 (NE555, TLC555), Schmitt inverter (one gate of a CD40106 or 74HC14), analog switch (one switch of a CD4066 or DG411), N-JFET (2N5457, J201, 2N3819).
  - Chips that share supply pins in real life (one gate of a 40106, one OTA of an LM13700) use a hidden supply set in the inspector; the 555 has its own VCC and GND pins.
- **Examples:** LED and switch, voltage divider, capacitor charging, RC low-pass filter, LC oscillator, half-wave rectifier, Zener regulator, light dimmer, blinking LEDs (astable multivibrator), transistor switch, CMOS inverter, op-amp amplifier, triangle and square LFO (two TL072s), OTA VCA (LM13700), 555 LED flasher, Schmitt trigger oscillator (40106), sample and hold (CD4066 and TL072), and to listen to: 555 beeper, Schmitt oscillator tone (turn the pot to change the pitch), OTA tremolo (an LM13700 VCA whose gain a slow LFO sweeps), LM13700 resonant filter (a 12 dB/octave state-variable filter with cutoff and resonance pots, on a square wave), wind (noise through that filter), effects: ring modulator (AD633), BBD chorus (MN3207), Fuzz Face, diode-clipper overdrive, vactrol lowpass gate; and to play: keyboard VCO (1 V/octave), mono synth (VCO, envelope and VCA) a full synth voice (VCO through the resonant filter and a VCA, one envelope opening both), and that voice playing a sequenced bassline; memristor hysteresis, memristor programming.
- **A real Mac document app:** one window per circuit, open/save as `.jspice` files, autosave, undo and redo for every edit, copy and paste, export the schematic as PNG or PDF, light and dark mode.

![CMOS inverter in dark mode](docs/cmos-dark.png)

![Memristor hysteresis with an I–V curve scope](docs/memristor.png)

![Triangle and square LFO with two TL072 op-amps](docs/lfo.png)

![Sample and hold: a CD4066 switch and a TL072 buffer](docs/sample-hold.png)

![Op-amp amplifier](docs/opamp.png)

![Light dimmer with a potentiometer and an NPN transistor](docs/dimmer.png)

## AI control (MCP)

JSpice comes with an MCP server, so an AI agent such as Claude can design, simulate and measure circuits: a physics harness for analog design. The agent describes a circuit as a netlist (parts, models and the nets their terminals join), and JSpice draws it as a tidy schematic, simulates it and reports waveforms, measurements and frequency responses.

Circuits are drawn the way a person would: the signal flows from left to right with the main path on straight lines, sources on the left, parts to ground hanging below the line with ground symbols, pull-ups standing above it, feedback arching over its op-amp, an oscillator's loop returning along the bottom, supply rails as flags (`+12V`, `VCC`), and real wires routed around the parts, with junction dots and few bends or crossings. **Circuit ▸ Tidy Up** (⌥⌘T, or the `tidy_up` tool) redraws any circuit, hand-drawn ones included, the same way, keeping every connection.

Tools: `list_parts`, `list_examples`, `load_example`, `new_circuit`, `build_circuit` (from a netlist), `add_part`, `add_wire`, `remove_part`, `tidy_up`, `set_parameter`, `set_model`, `set_switch`, `set_sequence` (a step pattern for the keyboard sources), `describe_circuit`, `simulate` (waveforms with min, max, mean, RMS, peak-to-peak and frequency for probes like `V(out)`, `I(R1)`, `V(U1.out)`; it can also play timed notes on the circuit's keyboard sources, such as `[{"at": 0, "note": "C4"}, {"at": 0.5, "off": true}]`), `measure`, `frequency_response` (gain and phase from a source to a probe), `save_circuit`, `open_circuit`.

To connect Claude:

1. In JSpice, choose **Circuit ▸ Copy MCP Server Configuration**. It copies something like this:

   ```json
   {
     "mcpServers": {
       "jspice": { "command": "/Applications/JSpice.app/Contents/MacOS/jspice-mcp" }
     }
   }
   ```

2. Claude Desktop: paste it into its configuration file (Settings ▸ Developer ▸ Edit Config) and restart it. Claude Code: `claude mcp add jspice /Applications/JSpice.app/Contents/MacOS/jspice-mcp`.

While JSpice is running with **Circuit ▸ Allow AI Control** on (the default), the agent works on the circuit in the front window: you see each change and can undo it. When JSpice is not running, `jspice-mcp` simulates on its own. `jspice-mcp --headless` always simulates on its own, and `--app` insists on the app.

## Install

Download **JSpice-macOS.zip** from the latest successful run of the [macos workflow](../../../actions/workflows/macos.yml) (under *Artifacts*), unzip it and move JSpice to Applications. It runs on macOS 14 or later, on Apple Silicon and Intel Macs.

The app is signed ad hoc but not notarized by Apple, so the first time macOS will refuse to open it. Either right-click JSpice and choose **Open**, or allow it under **System Settings → Privacy & Security → Open Anyway**. From the terminal you can instead run `xattr -dr com.apple.quarantine /Applications/JSpice.app`.

## Build it yourself

Requires Xcode 15 or later.

```
cd macos
swift test                 # simulation engine tests
./scripts/bundle.sh        # builds build/JSpice.app and build/JSpice-macOS.zip
open build/JSpice.app
```

## Shortcuts

| Key | Action |
| --- | --- |
| letter keys | choose a part (shown next to each part in the library) |
| `Esc` | back to selecting |
| `Space` | run / pause |
| `⌘↩` / `⇧⌘↩` | run or pause / reset |
| `⌘R` | rotate the selection |
| `F` or `⇧⌘R` | flip the selected transistors, op-amps and potentiometers |
| `⇧⌘E` | export the schematic as an image |
| `⌥⌘T` | tidy up: redraw the circuit as a neat schematic |
| `Delete` | delete the selection |
| `⌘C` `⌘X` `⌘V` `⌘A` | copy, cut, paste, select all |
| scroll, `⌘` + scroll, pinch | pan, zoom, zoom |
| `⌥` + drag on empty canvas | pan |
| `⌘=` `⌘-` `⌘0` | zoom in, out, to fit |
| scroll over a potentiometer | turn it |
| right-click a part | add a scope or I–V curve, rotate, flip, delete |
| `H` | net label: labels with the same name are connected; `GND` is ground |

## How it works

`Sources/CircuitKit` is the simulation engine, written for live stepping and tested on its own (`swift test`). It uses modified nodal analysis, like JSpice and SPICE:

- Wires and closed switches merge their ends into one node; their currents (for the dots) are recovered afterwards from Kirchhoff's current law.
- Capacitors and inductors use second-order Gear (BDF2) companion models: an LC circuit keeps oscillating at the right frequency, and unlike the trapezoidal rule a sudden step does not make currents ring from one time step to the next.
- Diodes, Zener diodes, LEDs, bipolar transistors (Ebers–Moll), MOSFETs (level 1), op-amps (an internal stage with a single pole at the gain-bandwidth, slew-rate limited, ahead of a smooth output limit), OTAs, JFETs and analog switches are solved with Newton-Raphson and junction voltage limiting at every time step. When a circuit snaps from one state to another, like the two transistors of a flip-flop changing over, Newton is guided to the new solution by gmin stepping: the junctions are briefly shunted and the shunts stepped down to nothing.
- 555 timers and Schmitt inverters switch between discrete states; a step in which one switches is solved again with the new state, so timing does not lag by a step.
- Memristors follow a threshold switching model (on resistance, off resistance, on and off thresholds, switching time) like the MSS models in JSpice.
- With sound on, a copy of the simulator runs on its own thread, four steps per sample at the output's rate (fewer if the circuit is too heavy), filling about 50 ms of sound ahead; the window's simulator takes on its state at each display frame to draw it. Each step is cheap: parameters are read once when the circuit loads, only the parts that need it are visited, and Newton-Raphson reuses its buffers. `jspice-mcp --benchmark` times every example at 48 kHz.
- `Pacing` estimates the circuit's time constants and periods to pick the speed and time step; `Simulator.advance` stops at a per-frame compute budget, so the app stays responsive however heavy the circuit is.

`Sources/JSpiceAutomation` holds the automation tools and the MCP server, `Sources/jspice-mcp` the stdio server, and `Sources/JSpice` the SwiftUI and AppKit app. CI builds it on macOS, runs the engine tests, runs `JSpice --self-test` (which draws a circuit with mouse events, moves, deletes, undoes, joins a part to a wire, turns a potentiometer and flips a switch, and checks the results), and renders screenshots with `JSpice --screenshots`.
