# Accessibility

What JSpice for Mac tells VoiceOver and other assistive apps, what works from the keyboard, and what does not yet.

All of this has been checked only through macOS's accessibility interface, by the app's self-test (`checkAccessibility` in `Sources/JSpice/SelfTestAccessibility.swift`), which reads the schematic's elements and performs their actions as VoiceOver would. It has never been tried with VoiceOver itself, by someone who uses it. Expect rough edges, and please report them.

## The schematic

The canvas is one group, named for the circuit and its state: "Schematic: 21 parts, running" (or paused, or stopped). Inside it is an element for each part, in reading order (top to bottom, then left to right), the order Tab selects them in. Wires and grounds are not elements of their own: what they join is told in the parts' help.

Each part's element has:

- **a label**, its name and kind: "R1, resistor", "Q1, NPN transistor", "net label +9V";
- **a value**, what the canvas writes beside it ("1 kΩ", "5 V") and, once the circuit has run, its live readings: "2.3 V across, 1.2 mA through", an LED "lit 40 %" or "dark", a switch open or closed, a push button held down or released;
- **help** saying what its terminals connect to, in words: "Between +9V and the base of Q1". A connection is named by its net label, its supply ("+9V") or GND, or else by the other terminals on it;
- **its frame** on screen, the box round its terminals, so VoiceOver's cursor outlines the part, and the part under the pointer is found.

Switches, footswitches and jacks are toggles, and a potentiometer is a slider from 0 to 100 %. VoiceOver's press flips a switch, holds a push button down until it is pressed again (so its effect can be heard and read), and on any other part selects it and shows the inspector. Increment and decrement turn a potentiometer by 5 %. The actions menu offers what the part's right-click menu does: **Select** (for switches and knobs), **Add Voltage Scope** and the other scopes, **MIDI Learn**, **Open Block**, **Rotate**, **Flip** and **Delete**.

VoiceOver hears "Selected R1, resistor" as Tab moves the selection while the canvas has the keyboard, "Added …" when a part appears and "Removed a part" when one goes, and each [toast](guide.md#the-window) as it appears.

## The rest of the window

- **Toolbar**: Run or Pause (with its key), the speed, **Sound** (and why it is unavailable without a speaker), the inspector's button, shown or hidden; the zoom buttons over the canvas.
- **Status bar**: the simulation's state and time, read as one element.
- **Dock**: each tab's name, whether it is shown, and for Problems how many there are; the dock's top edge is adjustable ("Dock height"), a step at a time down to folded.
- **Front panel**: knobs are adjustable, and turn by 5 % with the arrow keys when they have the keyboard focus; switches flip with Space or Return; a push button is held while Space is; lamps and the level meter read their state.
- **Scopes**: each plot read in words, with its present value and its range over the window; a frequency response or spectrum points to the figures beside it.
- **Library and palette**: each row says the part, its shortcut and whether it is the tool chosen; the ⌘K palette's rows can be pressed, and the highlighted row is spoken as the arrow keys move it.
- **Welcome view and Examples window**: examples by title, with whether they make sound; gallery cards by title, category and badges, with the summary as their hint; categories as headings.
- The inspector, Settings and the sketch editor use standard controls named by their visible labels; an inspector slider is named for its parameter and reads its value.

**Reduce Motion** (System Settings ▸ Accessibility ▸ Display) is followed in three places: the toasts fade in place instead of sliding in, the pill that says what is being placed, and the banners under it, appear without sliding, and the front panel's toggle switches flip without a spring. Nothing else in the app is animated by it.

## Not covered yet

- **Placing parts and drawing wires need a pointer.** A part's key, the library or the ⌘K palette choose a part, but it is placed with a click or a drag; wires are drawn the same way. From the keyboard, Tab selects parts, the arrow keys move them, Return types a value, and the inspector edits the rest. An AI agent can build a circuit from a netlist instead ([mcp.md](mcp.md)).
- **The breadboard, stripboard and perfboard views** have no accessibility of their own: the board and its holes are a picture. Their side panels' lists and the bill of materials are ordinary text.
- **The microcontroller views** (the inspector's program section, the sketch editor's messages, the Chip tab's serial monitor, bus trace and pins, Chip Support) were given nothing beyond SwiftUI's defaults.
- The canvas's moving dots, colours and glow are not described beyond the readings above.
