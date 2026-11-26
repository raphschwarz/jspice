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
- An example gallery (File ▸ New from Example…, Help ▸ Example Gallery): examples in categories, each opening in a
  window of its own instead of replacing your drawing. The welcome view, the library and the palette lead to it.
- A resizable dock under the canvas, on the schematic and on the boards, with tabs for the scopes, the front panel,
  a chip's serial monitor, bus trace and pins, and a list of every problem in the circuit.
- A Settings window for AI control, the Anthropic API key and chip support.
- A Microcontroller menu for the chips, with Chip Support… to install and check the compilers.
- Sketch builds show their steps, warnings and problems in plain words as they go, and can be cancelled. Chip support
  downloads can be cancelled too.

### Changed

- Imports and exports are in the File menu.
- Messages about imports, exports and model downloads appear as notices over the canvas instead of dialogs; long
  reports open in a sheet you can read and copy.
- Circuit files record the version of their format. A file saved by a newer JSpice still opens: what this version
  cannot read is left out of the circuit, you are told what was left out, and it is written back unchanged when you
  save.
- AI agents can control the app only after you allow it (JSpice ▸ AI Control). `jspice-mcp` keeps working on its own
  when the app quits.
- Uploading a sketch to a board from an AI agent or the command line checks the chip support it needs first, and
  says what went wrong if no build succeeds. STM32 parts no longer ask for chip support they do not need.
- The examples on the welcome view wrap to the window's width and scroll in a short window.

### Fixed

- Parts on a microcontroller's buses (such as memories and converters) keep what they hold through an edit,
  when sound is switched on or off, and when the simulator throws away a step.
- A DMA transfer on an emulated chip can no longer hang the simulator or crash it.
- Unusual STM32 interrupt or SDADC settings in firmware no longer crash the emulator.
- A cancelled or failed sketch build no longer leaves a half-built Arduino core behind.

### Security

- The debugger (GDB) server answers a malformed packet with an error instead of crashing.
- A firmware HEX file whose records lie far apart is refused instead of filling gigabytes of memory.
- A downloaded toolchain archive whose checksum cannot be checked is not installed.

## 1.0

The first version: a native Mac circuit simulator in the spirit of iCircuit and the Falstad applet. Draw a circuit
and watch it run live, hear it and play sound and MIDI into it, with scopes, frequency response, noise and tolerance
analyses, emulated AVR, RP2040 and STM32 microcontrollers running real Arduino sketches, an Audio Unit for music apps,
and an MCP server so AI agents can build and measure circuits.
