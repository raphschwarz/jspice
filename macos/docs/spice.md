# SPICE netlists and makers' models

JSpice reads SPICE netlists and makers' model files, and writes decks that ngspice and LTspice run. Each import reports what it did, and what it left out, in a toast over the canvas, with the whole report a click away.

- [Importing a netlist](#importing-a-netlist)
- [Makers' models](#makers-models)
- [Downloading a maker's model](#downloading-a-makers-model)
- [Running an op-amp on its maker's model](#running-an-op-amp-on-its-makers-model)
- [Exporting a netlist](#exporting-a-netlist)

## Importing a netlist

**File ▸ Import ▸ SPICE Netlist…** (or `import_spice`) draws a netlist as a schematic, and lists what it leaves out. It reads:

- R, C, L, V and I sources (DC, SIN, PULSE; a 0 V source becomes an ammeter, unless a controlled source reads its current);
- diodes, bipolar transistors, MOSFETs and JFETs with their `.model` parameters;
- coupled inductors (a transformer);
- controlled sources (E, F, G and H with a gain, POLY, VALUE or TABLE, and B sources with V= or I=);
- `.param` constants, `.func` functions and `{expressions}` of them;
- subcircuits (blocks) with their parameters (`PARAMS:` defaults, an instance's own values, `.param` inside them; a block for each different set).

The model files a deck names are read from beside it: `.include file`, and `.lib file section` for one section of a library (or `.lib file` for all of it, as PSpice and LTspice read it), so a maker's model file can be imported as it comes.

- A diode's, transistor's or JFET's area (after its model's name, or `AREA=` and `M=`) scales its card as in ngspice.
- Switches are behavioural sources: PSpice's VSWITCH and ISWITCH (S and W) with the resistance its reference manual gives (its logarithm a smooth cubic between the off and on controls), and ngspice's SW and CSW read the same way between VT − VH and VT + VH, without their hysteresis (the import says so).
- A resistor, capacitor or inductor may name a model (PSpice's `R1 a b R_NOISELESS 1k`): its R, C or L scales the value, and a resistor at absolute zero (`T_ABS=-273.15`, as maker's macromodels mark the resistors that stand for no real one) or with `noisy=0` makes no thermal noise.

How behavioural sources are solved, and how imported decks are checked against ngspice, is in [how-it-works.md](how-it-works.md#controlled-sources).

## Makers' models

**File ▸ Import ▸ Maker's Model…** (or `import_model`) takes a part's model file as its maker publishes it (an op-amp's `.lib` or `.mod` from TI, Analog Devices, onsemi…, downloaded from the part's page): one of its subcircuits becomes a block in the library, its pins named as the file names them, kept with where it came from: the file's name and SHA-256 (so the very file, and its revision, can be found again), the comment lines it starts with (where makers give the part, the model's revision and its terms) and when it was imported. Makers' files are theirs to give out, so JSpice ships none: each one is imported from the maker's own download.

A model with five pins (in a model's usual order: +in, −in, V+, V−, out) is measured as an op-amp at ±15 V, to set beside its datasheet:

- input offset voltage and supply current (as a follower);
- open-loop gain;
- gain-bandwidth product (100 times where the gain falls through 40 dB);
- unity-gain frequency and phase margin (in an inverting stage with its + input grounded, as datasheets measure them, so the common-mode rejection a follower would fold in stays out);
- slew rate on a 10 V step (10–90 % of the output's swing, from its last 10 % crossing before its 90 % one, as a follower or in an inverting stage of gain −1 as the part's datasheet measures it: an output can jump at the step's instant through the inputs' clamp diodes or its input stage, and fall back before it slews);
- output swing into the load.

A deck exported with such a block names its file and SHA-256 above its subcircuit.

## Downloading a maker's model

**File ▸ Import ▸ Download Maker's Model** fetches the parts JSpice knows where to find straight from their makers (TI's TL072, TL074, RC4558, UA741, LM358, OPA2134, OPA1612, OPA1642, OPA1656 and OPA1678 so far, `MakerModelCatalog`; `list_maker_models` for an agent): the archive from the maker's site, the model file in it checked against the SHA-256 of the revision the catalog names (a newer revision is refused until it has been checked), imported, measured at its datasheet's supplies and load, and shown beside the datasheet's figures (the document, revision and table are named) and what ngspice measures on the same file.

`tools/spice-reference/maker_models.py` downloads each and spells PSpice's switches, LIMIT and IF for ngspice; where ngspice gives up on a run, "timestep too small" as a model's overload sensing chatters, it tries Gear's rule and an operating point already driven, and a figure no way gives is left out. CI downloads each and requires JSpice's figures to match ngspice's.

What the models are known to get wrong:

- TI's 1989 TL072 model is of the original die (3.3 MHz, 13 V/µs, where today's TL07xC is 5.25 MHz and 20 V/µs) and draws 14.2 mA where the datasheet gives 1.4.
- The OPA1678's swings 0.3 to 0.5 V short of its datasheet's output range into 2 kΩ.
- The OPA1612's gain-bandwidth product is 92 MHz where its datasheet gives 80.
- TI's 1989 RC4558 model is the part as its datasheet gave it before its 2024 revision (3 MHz, 300 V/mV, ±13 V into 2 kΩ, where it now gives 4 MHz, 830 V/mV and ±13.8 V), and its UA741 the classic 741 (1.67 mA), where the 2026 datasheet describes TI's present die (0.13 mA).
- The TL074's file holds the TL072's model.

## Running an op-amp on its maker's model

An op-amp part whose model is in the catalog (TL072, TL074, LM358, OPA2134, OPA1612, OPA1642, OPA1656, OPA1678; the LM741 runs TI's UA741 and the JRC4558 TI's RC4558, the same designs) can run its maker's model in place of JSpice's own equations: the inspector's **Maker's Model** switch (or `use_maker_model`) downloads the file once (it is kept in ~/Library/Application Support/JSpice/Maker Models, on this Mac only) and puts the model's parts in the op-amp's place, on ideal supplies (± a supply about the op-amp's midpoint, by default as the breadboard supplies it: ± the swing and 1.5 V, or a single supply's 0 V and twice its midpoint, a pedal's 9 V). The circuit keeps the model with its provenance and exports it as the model's subcircuit.

Closer to the part, it is also slower, but TI's newer models play live: at 48 kHz, one step a sample, one OPA2134 takes about 6.5 µs a step on CI's Mac (3 times real time) and two in a row, as a pedal's two op-amps, about 13 µs (1.5 times real time, whose budget is 20.8 µs), two OPA1656s about 14 µs; TI's LM358 model, whose output stage switches itself off and on again about its crossover, about 14 µs (1.5 times real time). Its crossings take a few iterations more than the rest of the cycle, where they took a dozen: how the engine gets there is in [how-it-works.md](how-it-works.md#makers-models-at-audio-rate). `jspice-mcp --benchmark-maker PART [seconds] [stages] [SWITCH=on|off…]` times one, or several in a row.

## Exporting a netlist

**File ▸ Export ▸ SPICE Netlist…** (or `export_spice`) writes a deck for ngspice or LTspice with JSpice's own equations: op-amps and tubes as behavioural sources, transformers as coupled inductors, blocks as subcircuits. A Loop Probe is written as the 0 V source SPICE breaks loops with. Parts with no SPICE element (chips, microcontrollers) are named in comments.
