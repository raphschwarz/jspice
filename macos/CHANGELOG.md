# Changelog

All notable changes to JSpice for Mac. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/). The version being built is in `VERSION`; to release
it, rename **Unreleased** to that version with the date (`## 1.1.0 - 2026-12-01`), start a new empty **Unreleased**,
and push the tag `v1.1.0` (see `.github/workflows/release.yml`). The release's notes are that version's section here.

## Unreleased

### Added

- Releases: JSpice is published on the repository's Releases page as `JSpice-<version>-macOS.zip` with its SHA-256
  checksum, so there is no need to sign in to GitHub to download it. **About JSpice** shows the version, the build
  and the commit it was built from, and `jspice-mcp --version` prints them.
- **Check for Updates…** in the JSpice menu asks GitHub for the newest release, only when you choose it.
- An Examples window (File ▸ New from Example…, Help ▸ Example Gallery): every example by category, with a drawing of
  its schematic and a search field. The welcome view, the library and the ⌘K palette lead to it.
- A resizable dock under the canvas, on the schematic and on the boards, with tabs for the scopes, the front panel,
  a chip's serial monitor, bus trace and pins, and the circuit's problems.
- Problems name their parts. Each is an error, a warning or a note, most with a hint of what to do; the Problems tab
  lists them by severity, and clicking one selects its parts and brings them into view. The parts concerned carry a
  red or orange badge on the canvas, hovering one says what is wrong in the status bar, and the inspector shows a
  selected part's problems.
- New warnings: a circuit with no ground, parts not connected to ground or to the rest of the circuit, parts with no
  DC path to ground, a part connected to nothing, a terminal connected to nothing, and a simulation that keeps
  failing to settle (naming where).
- For AI agents, `describe_circuit` and `simulate` return the problems as `diagnostics`, each with its severity,
  hint and the parts it names.
- Drawing: the Wire tool draws a wire with a corner for a slanting drag (⇧ for one straight piece at any angle), and a
  drag from a part's free end draws a wire from it without choosing the tool. Double-click a part, or press Return,
  to type its value on the canvas. Right-click the empty canvas for Paste, Add Part…, Select All, Zoom to Fit and Tidy
  Up.
- The inspector edits several selected parts at once: their shared model and the parameters they have in common,
  showing Mixed where they differ, each change one undo step for all of them.
- ↑ and ↓ in a value's field step to the next standard value (E12, or E24 with ⌥) for resistors, capacitors and
  inductors, and by a round amount for other values. A field's help tag gives its usual range.
- A Settings window (JSpice ▸ Settings…) for AI control, the Anthropic API key and chip support.
- A Microcontroller menu: Edit Sketch…, Upload Sketch, Load Firmware… and Chip Support….
- Sketch builds show their steps and progress and can be cancelled. Errors and warnings on the sketch's own lines are
  listed by line, and a failure no line explains is said in plain words (a function never defined, a sketch too big
  for the chip, a library that is not available, with the libraries that are).
- Chip support installs go on in the background when their window is closed, show their progress wherever Chip
  Support is open, and can be cancelled.
- VoiceOver: the schematic is described part by part, each with its value, live readings and what it connects to,
  with actions to flip switches, hold buttons, turn knobs, add scopes, rotate and delete. The dock, front panel,
  scopes, library, palette, welcome view and Examples window are labelled, front-panel controls work from the
  keyboard, and some animations follow Reduce Motion. This has been checked through macOS's accessibility interface,
  not yet with VoiceOver itself; the details and what is not covered are in `docs/accessibility.md`.

### Changed

- Imports and exports are in the File menu; the Circuit menu keeps what acts on the circuit.
- Results of imports, exports, model downloads and saved blocks appear as notices over the canvas instead of dialogs,
  with Show in Finder, Undo or Try Again where they apply; long reports open in a sheet you can read and copy.
  Warnings and failures stay until dismissed.
- Examples open in a window of their own instead of replacing your drawing (in the same window only when it is empty).
- When a simulation fails, the message says why: voltage sources in parallel, a loop of voltage sources and wires, a
  current source with nowhere to send its current, a voltage or current that became infinite, or an analysis that ran
  too long.
- Circuit files record the version of their format. A file saved by a newer JSpice still opens: what this version
  cannot read is left out of the circuit and listed in the Problems tab, and it is written back unchanged when you
  save.
- AI agents can control the app only after you allow it (JSpice ▸ AI Control (MCP): Ask, Always Allow or Don't Allow).
  `jspice-mcp` keeps working on its own when the app quits.
- Uploading a sketch from an AI agent or the command line checks the chip support it needs first, and says what went
  wrong if no build succeeds. STM32 parts are no longer offered chip support or sketch commands they cannot use.
- Upload Sketch on a chip with no sketch yet loads its board's blink, from the menu as from the inspector.
- Esc steps back one thing at a time: a value being typed, a MIDI Learn, the part being placed, then the selection.
- Pasted parts land under the pointer.
- The inspector puts Rotate, Flip and Delete beside the part's name and the scope buttons beside its readings, and
  folds the SPICE model parameters, MIDI and Movement, remembering which are open. Text typed into a value field that
  is not a value stays, marked, with what the field takes, instead of being put back silently.
- The toolbar no longer has zoom buttons (they are in the corner of the canvas) or a Panel button (the panel is a tab
  of the dock). Each new window remembers the last view settings: values, current, the inspector and the dock.
- The examples on the welcome view wrap to the window's width and scroll in a short window.

### Fixed

- Parts on a microcontroller's buses (such as memories, converters and LED drivers) keep what they hold through an
  edit, when sound is switched on or off, and when the simulator throws away a step.
- A DMA transfer on an emulated chip can no longer hang the simulator or crash it.
- Unusual STM32 interrupt or SDADC settings in firmware no longer crash the emulator.
- A cancelled or failed sketch build no longer leaves a half-built Arduino core behind.
- A second copy of JSpice no longer takes AI control away from the first.
- An agent's schematic capture in the app uses the API key kept in the keychain.

### Security

- The debugger (GDB) server answers a malformed packet with an error instead of crashing, and checks each packet's
  checksum.
- A firmware HEX file whose records lie far apart is refused instead of filling gigabytes of memory.
- A downloaded toolchain archive whose checksum is not a SHA-256, or that is not served over HTTPS, is not installed.

## 1.0

The first version: a native Mac circuit simulator in the spirit of iCircuit and the Falstad applet. Draw a circuit
and watch it run live, hear it and play sound and MIDI into it, with scopes, frequency response, noise and tolerance
analyses, emulated AVR, RP2040 and STM32 microcontrollers running real Arduino sketches, an Audio Unit for music apps,
and an MCP server so AI agents can build and measure circuits.
