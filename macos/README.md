# JSpice for Mac

A native macOS circuit simulator in the spirit of iCircuit and the Falstad applet: draw a circuit and watch it run live, with voltages shown as colour and current as moving dots.

![LED and switch](docs/led.png)

## Features

- **Draw circuits directly.** Pick a part in the library (or press its key: `R` resistor, `C` capacitor, `W` wire, …), then click to place it or drag to set its length and direction. Parts connect where their ends meet, and a part dropped onto the middle of a wire joins it with a T-junction (wires that merely cross stay apart). Wires stretch when you move the parts they connect.
- **Live simulation.** The circuit simulates while you draw. Voltages are coloured (green positive, red negative, grey at 0 V), current flows as dots, LEDs and lamps glow, and memristors show their internal state.
- **Real time when possible.** Circuits that change slowly enough to watch run in real time (a capacitor charging over a second, a 1 Hz memristor loop). Faster ones run in slow motion automatically, for example a 100 Hz filter at 5 ms per second, and the status bar says so. If a circuit is too heavy to keep up, it runs as fast as it can and the status bar shows how far behind it is. You can also set the speed yourself.
- **Interact while it runs.** Click switches, hold push buttons, scroll over a potentiometer to turn it, and drag sliders in the inspector to change values live.
- **Scopes** for any part's voltage, current, power or resistance over time, or its current against its voltage (an I–V curve, such as a memristor's pinched hysteresis loop).
- **Library of parts:** wire, ground, resistor, potentiometer, lamp, capacitor, inductor, DC/AC/square-wave voltage sources, current source, switch, push button, diode, Zener diode, LED, NPN and PNP transistors, NMOS and PMOS transistors, op-amp, memristor, voltmeter probe, ammeter. Transistors, op-amps and potentiometers can be flipped as well as rotated.
- **Examples:** LED and switch, voltage divider, capacitor charging, RC low-pass filter, LC oscillator, half-wave rectifier, Zener regulator, light dimmer, blinking LEDs (astable multivibrator), transistor switch, CMOS inverter, op-amp amplifier, memristor hysteresis, memristor programming.
- **A real Mac document app:** one window per circuit, open/save as `.jspice` files, autosave, undo and redo for every edit, copy and paste, export the schematic as PNG or PDF, light and dark mode.

![CMOS inverter in dark mode](docs/cmos-dark.png)

![Memristor hysteresis with an I–V curve scope](docs/memristor.png)

![Op-amp amplifier](docs/opamp.png)

![Light dimmer with a potentiometer and an NPN transistor](docs/dimmer.png)

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
| `Delete` | delete the selection |
| `⌘C` `⌘X` `⌘V` `⌘A` | copy, cut, paste, select all |
| scroll, `⌘` + scroll, pinch | pan, zoom, zoom |
| `⌥` + drag on empty canvas | pan |
| `⌘=` `⌘-` `⌘0` | zoom in, out, to fit |
| scroll over a potentiometer | turn it |
| right-click a part | add a scope or I–V curve, rotate, flip, delete |

## How it works

`Sources/CircuitKit` is the simulation engine, written for live stepping and tested on its own (`swift test`). It uses modified nodal analysis, like JSpice and SPICE:

- Wires and closed switches merge their ends into one node; their currents (for the dots) are recovered afterwards from Kirchhoff's current law.
- Capacitors and inductors use second-order Gear (BDF2) companion models: an LC circuit keeps oscillating at the right frequency, and unlike the trapezoidal rule a sudden step does not make currents ring from one time step to the next.
- Diodes, Zener diodes, LEDs, bipolar transistors (Ebers–Moll), MOSFETs (level 1) and op-amps (high gain with a smooth output limit) are solved with Newton-Raphson and junction voltage limiting at every time step. When a circuit snaps from one state to another, like the two transistors of a flip-flop changing over, Newton is guided to the new solution by gmin stepping: the junctions are briefly shunted and the shunts stepped down to nothing.
- Memristors follow a threshold switching model (on resistance, off resistance, on and off thresholds, switching time) like the MSS models in JSpice.
- `Pacing` estimates the circuit's time constants and periods to pick the speed and time step; `Simulator.advance` stops at a per-frame compute budget, so the app stays responsive however heavy the circuit is.

`Sources/JSpice` is the SwiftUI and AppKit app. CI builds it on macOS, runs the engine tests, runs `JSpice --self-test` (which draws a circuit with mouse events, moves, deletes, undoes, joins a part to a wire, turns a potentiometer and flips a switch, and checks the results), and renders screenshots with `JSpice --screenshots`.
