# AI control (MCP)

JSpice comes with an MCP server, so an AI agent such as Claude can design, simulate and measure circuits: a physics harness for analog design. The agent describes a circuit as a netlist (parts, models and the nets their terminals join), and JSpice draws it as a tidy schematic, simulates it and reports waveforms, measurements and frequency responses.

Circuits are drawn the way a person would: the signal flows from left to right with the main path on straight lines, sources on the left, parts to ground hanging below the line with ground symbols, pull-ups standing above it, feedback arching over its op-amp, an oscillator's loop returning along the bottom, supply rails as flags (`+12V`, `VCC`), and real wires routed around the parts, with junction dots and few bends or crossings. **Circuit ▸ Tidy Up** (⌥⌘T, or the `tidy_up` tool) redraws any circuit, hand-drawn ones included, the same way, keeping every connection.

## Connecting Claude

1. In JSpice, open **JSpice ▸ Settings ▸ AI Control** and click **Copy MCP Server Configuration**. It copies something like this:

   ```json
   {
     "mcpServers": {
       "jspice": { "command": "/Applications/JSpice.app/Contents/MacOS/jspice-mcp" }
     }
   }
   ```

2. Claude Desktop: paste it into its configuration file (Settings ▸ Developer ▸ Edit Config) and restart it. Claude Code: `claude mcp add jspice /Applications/JSpice.app/Contents/MacOS/jspice-mcp`.

## Who may take control

While JSpice is running, the agent works on the circuit in the front window: you see each change and can undo it. An agent in control can change the open circuit, read and write files anywhere your account can, install chip support and open a GDB port, so JSpice asks first. **JSpice ▸ AI Control (MCP)** (also in **JSpice ▸ Settings ▸ AI Control**, which says whether JSpice is listening) has three settings:

- **Ask When an Agent Connects** (the default): the first agent to connect after JSpice starts brings up a prompt. **Allow** lets agents work until you quit JSpice, **Always Allow** switches the setting to Always Allow, and **Don't Allow** refuses them until you quit (or choose Ask again). Until you answer, and after Don't Allow, the agent's tool calls fail with a message saying what to do in JSpice.
- **Always Allow**: agents get control without a prompt.
- **Don't Allow**: JSpice does not listen for agents at all.

If you had turned the old Allow AI Control switch of earlier versions off, it stays off; if it was on, it becomes Ask. JSpice cannot tell which program is connecting, only that it runs as you on this Mac.

## Without the app

When JSpice is not running or not listening (set to Don't Allow, or a second copy while the first one serves agents), `jspice-mcp` simulates on its own. If JSpice quits mid-session, requests it had not answered fail, and `jspice-mcp` carries on alone on a fresh, empty circuit, telling the agent so in its next tool call's result. `jspice-mcp --headless` always simulates on its own, and `--app` insists on the app: without it `jspice-mcp` does not start, and if JSpice quits, tool calls fail.

`jspice-mcp --version` prints the version, build and commit. It also has command-line modes for measuring the app: `--benchmark` (every example at 48 kHz), `--benchmark-maker` ([spice.md](spice.md#running-an-op-amp-on-its-makers-model)) and `--capture-eval` ([guide.md](guide.md#schematic-capture)).

## Tools

Every tool the server offers, as defined in `Sources/JSpiceAutomation/CircuitSession.swift`. `list_parts` gives each part kind's terminals, parameters and models; probes are written like `V(out)`, `I(R1)`, `V(U1.out)`.

`describe_circuit` (always) and `simulate` (when there are any) return a `diagnostics` array: what the app's Problems tab lists ([guide.md](guide.md#problems)), each entry with its `severity` (`error`, `warning` or `note`), `message`, a `hint` when there is something to do, and the names of the `parts` it is about, for example `{"severity": "warning", "message": "R2 is not connected to anything.", "hint": "Wire it into the circuit, or delete it.", "parts": ["R2"]}`. Their `problems` array is the errors' and warnings' messages alone.

### Circuits

| Tool | What it does |
| --- | --- |
| `list_parts` | every part kind with its terminals (in order), parameters (with units, defaults and ranges) and the real parts it can behave like (models) |
| `list_examples` | the built-in example circuits |
| `load_example` | replaces the circuit with a built-in example |
| `new_circuit` | starts an empty circuit |
| `build_circuit` | builds a circuit from a netlist and draws it as a tidy schematic; replaces the circuit unless `append` is true |
| `add_part` | adds one part, by its connections or at grid positions |
| `add_wire` | draws a wire between two grid points |
| `remove_part` | removes a part by name |
| `tidy_up` | redraws the circuit as a tidy schematic, keeping connections, values and scopes |
| `set_parameter` | sets one parameter of a part |
| `set_model` | makes a part behave like a real part (an op-amp as "TL072" or "LM358") |
| `set_switch` | opens or closes a switch or push button |
| `set_temperature` | the temperature the circuit works at, in °C (27 by default) |
| `describe_circuit` | every part with its kind, model, parameters and nodes, and the circuit's diagnostics: each problem's severity, message, hint and the parts it names; with `load_notes`, what this version left out of a file a newer JSpice saved (kept in the file) |
| `define_block` | makes a netlist into a block, with `port` parts as its pins, used as `{"kind": "block", "block": "name", ...}` as often as needed |
| `list_blocks` | the blocks that can be used, with their pins |
| `save_circuit` | saves the circuit as a `.jspice` file |
| `open_circuit` | opens a `.jspice` file and describes it as `describe_circuit` does; a newer JSpice's file opens with what this version can read, and `load_notes` says what was left out |

### Simulation and measurement

| Tool | What it does |
| --- | --- |
| `simulate` | a transient run from rest (or continuing the last one): waveforms with min, max, mean, RMS, peak-to-peak, final value and frequency for each probe, and the circuit's diagnostics; it can also play timed notes on the keyboard sources, such as `[{"at": 0, "note": "C4"}, {"at": 0.5, "off": true}]`, and move knobs back and forth by themselves |
| `measure` | every net voltage and every part's voltage, current and power at the end of the last simulation |
| `frequency_response` | gain and phase from a source to a probe, with the peak and the −3 dB points: by default a small-signal analysis around the operating point the circuit settles to, exact and instant; or `"method": "transient"`, which measures each frequency with the source's own amplitude, clipping and all |
| `spectrum` | fundamental, THD, each harmonic's level and the strongest other peaks of a probe's signal |
| `noise` | output and input-referred noise density, the total over a band and the parts it comes from |
| `loop_gain` | a feedback loop's gain at a loop probe, with its phase and gain margins and crossover |
| `impedance` | a node's or a source's impedance against frequency |
| `stress` | rated parts against their ratings over a run, and the hottest parts |
| `sweep` | a value stepped through a list or range, measuring a response, an operating point or a waveform at each step |
| `monte_carlo` | every value drawn within tolerance, many times: the spread of each measurement |
| `optimize` | part values found to meet targets (a corner frequency, a gain within a range, the most output), then moved to E12, E24 or E96 values |

### Sound and play

| Tool | What it does |
| --- | --- |
| `set_audio_input` | a WAV file for an audio input to play (the built-in guitar riff without one) |
| `render_audio` | what the speaker hears, as a 24-bit WAV file, with its peak level and how much clipped |
| `map_midi` | a MIDI controller for a knob or switch, as MIDI Learn does |
| `set_sequence` | a step pattern for the keyboard sources |

### Microcontrollers

| Tool | What it does |
| --- | --- |
| `upload_sketch` | compiles an Arduino sketch into a microcontroller, returning the firmware size or the compiler's errors by line (and a `problem` when no line of the sketch says what failed), with the compiler's warnings by line either way |
| `load_firmware` | loads an Intel HEX file or raw image built elsewhere, as a programmer flashes it |
| `read_serial` | what a microcontroller printed, and text to send it |
| `read_bus_trace` | what went over an STM32's SPI, I²S, I²C and USART buses, decoded as a logic analyzer would |
| `read_chip_state` | what each of an STM32's pins carries as its firmware set it up, its clock, how often it reset itself, what it reached that the model does not run |
| `gdb_server` | starts or stops a GDB server for an STM32's firmware |
| `install_chip_support` | installs the compiler and core sketches need: avr (about 40 MB) or rp2040 (about 240 MB) |

### SPICE, models and drawings

| Tool | What it does |
| --- | --- |
| `import_spice` | replaces the circuit with a SPICE netlist, drawn as a tidy schematic; returns what was left out |
| `export_spice` | the circuit as a deck for ngspice or LTspice |
| `import_model` | a maker's model file, or a part downloaded from its maker, into the block library, with its provenance and, for an op-amp, its datasheet figures measured |
| `list_maker_models` | the parts whose models JSpice can download from their makers, with each file's revision and SHA-256 and what it is known to get wrong |
| `use_maker_model` | runs an op-amp part on its maker's model (or back on JSpice's own) |
| `capture_schematic` | a drawing's file into the circuit; needs an Anthropic API key: in the app, the one it keeps in the keychain; on its own, `ANTHROPIC_API_KEY` in the server's environment |

### Boards

| Tool | What it does |
| --- | --- |
| `breadboard` | the circuit on full, half or mini breadboards: each leg's hole, the jumpers, the rails and off-board wiring, checked against the schematic |
| `stripboard` | the circuit on stripboard: holes, cuts, links and off-board wiring, checked against the schematic |
| `perfboard` | the circuit on perfboard: holes, trails, links and off-board wiring, checked against the schematic |
| `bom` | the bill of materials for any of them |
| `board_sheet` | any of them as a printable SVG at true size |
| `export_kicad` | a KiCad netlist for a printed circuit board; returns the parts left for KiCad's footprint assignment |
