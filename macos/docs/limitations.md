# Limitations

What JSpice for Mac does not do, or does only approximately.

## Device models

Bipolar transistors are SPICE's Gummel-Poon model, as ngspice implements it, without excess phase, the substrate junction or the resistances' temperature coefficients. Diodes, Zener diodes and LEDs are SPICE's diode, without the sidewall, tunnelling and recombination currents or the temperature coefficients of BV and RS. JFETs are ngspice's level 1, without PSpice's extensions (the gate junction's emission and grading coefficients, recombination and impact ionisation). MOSFETs are ngspice's level 1 with their bulk tied to their source; level 2 and 3 cards are read as level 1, and there are no sidewall junctions. There is no flicker (1/f) noise. Transformer and inductor cores saturate without hysteresis.

The cross-check ([how-it-works.md](how-it-works.md#checked-against-ngspice)) compares JSpice with ngspice running these same equations, which shows the numerical error, not how far a part's model is from the real part: the models in the Model menu are approximations, until each is replaced by its maker's card. Some makers' own models are known to differ from their datasheets; the list is in [spice.md](spice.md#downloading-a-makers-model).

Other simplifications, described with their parts in [parts.md](parts.md):

- Voltage regulators have no current limit or thermal shutdown.
- The FV-1's programs are rewritten, since Spin's code is not published.
- ngspice's SW and CSW switches are imported without their hysteresis ([spice.md](spice.md#importing-a-netlist)).

## Analyses

Transient and small-signal analysis only. There is no DC sweep, and noise analysis has no flicker (1/f) noise. Small-signal analysis linearises around the circuit's present state; for chips, only the audio paths (a filter's input, a VCA's input and control, delay lines, a sample and hold while it tracks) pass small signals, and their control inputs (a filter's cutoff CV, a delay's clock) are held where they are.

Part stress checks only parts with a rating: a transistor's, a pot's or an op-amp's limits are not checked yet ([guide.md](guide.md#scopes-and-analyses)).

## Microcontrollers

SPI and I²C work as masters only, with no slave mode. The STM32 compiles no sketches (its firmware is built elsewhere); its SPI, I²C and I²S reach the codec part, not other bus parts bit by bit; a firmware whose I²S port is a slave to its codec (Rings' later boards) runs at 48 kHz. The F373's I²C is kept, not run. The AVR has no watchdog, sleep modes or analog comparator. The Pico runs one core, and its firmware cannot write to flash (no LittleFS or EEPROM emulation). See [microcontrollers.md](microcontrollers.md).

## Schematic capture

A drawing read by schematic capture lists the values it was unsure of and anything it left out; check it against the drawing before trusting a simulation ([guide.md](guide.md#schematic-capture)).

## Distribution

A build is notarized only when the release workflow has Apple's signing secrets; otherwise it is signed ad hoc, its release notes say so, and macOS asks before opening it the first time ([README](../README.md#install)).
