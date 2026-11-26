# Parts and models

The library on the left of the window lists every part by section; its search (and the ⌘K palette) finds a part by its name, its category or a real part it models. Many parts are one symbol with the specific part chosen in the inspector's **Model** menu, and each model behaves as the real part does in the ways listed below. How the device models are solved, and how they are checked against ngspice, is in [how-it-works.md](how-it-works.md); what they leave out is in [limitations.md](limitations.md).

- [The library](#the-library)
- [Op-amps, OTAs and multipliers](#op-amps-otas-and-multipliers)
- [Delays, reverbs and vactrols](#delays-reverbs-and-vactrols)
- [Synth chips](#synth-chips)
- [Tubes and transformers](#tubes-and-transformers)
- [Diodes and transistors](#diodes-and-transistors)
- [CMOS logic and converters](#cmos-logic-and-converters)
- [Audio parts](#audio-parts)

## The library

Wire, ground, net label, resistor, potentiometer, lamp, capacitor, inductor, DC/AC/square-wave voltage sources, current source, switch, push button, diode, Zener diode, LED, NPN and PNP transistors, NMOS and PMOS transistors, N- and P-channel JFETs, op-amp, OTA, analog multiplier, 555 timer, Schmitt inverter, analog switch, CMOS logic (gates, D flip-flop, decade and binary counters, analog multiplexers, phase-locked loop), unbuffered CMOS inverter, bucket-brigade delay line, digital echo (PT2399), vactrol, comparator, synth chips (VCO, VCF, ADSR envelope, VCA, sample and hold, clock divider), microcontrollers (ATmega328P / Arduino Uno, ATmega2560 / Arduino Mega, ATtiny85, RP2040 / Raspberry Pi Pico, STM32F405, STM32F373, STM32F103; see [microcontrollers.md](microcontrollers.md)), audio codecs (WM8731, CS4270/CS4271, PCM3060, AK4558, AK4556), LED drivers (PCA9685, TLC5947), I²C EEPROMs (24LC02B to 24LC512), a CV DAC (DAC8568, DAC8564, DAC8552, DAC8551, DAC7554), memristor, voltmeter probe, ammeter, speaker, keyboard pitch and gate, white noise, audio input, triode, pentode, transformer. The instruments include the **Loop Probe** ([guide.md](guide.md#scopes-and-analyses)), and the Blocks section holds the **Port** part and your saved blocks ([guide.md](guide.md#blocks-circuits-as-parts)).

Transistors, op-amps, OTAs, chips and potentiometers can be flipped as well as rotated. Chips that share supply pins in real life (one gate of a 40106, one OTA of an LM13700) use a hidden supply set in the inspector; the 555 has its own VCC and GND pins. Potentiometers: linear or audio taper.

Memristors follow a threshold switching model (on resistance, off resistance, on and off thresholds, switching time) like the MSS models in JSpice.

## Op-amps, OTAs and multipliers

- **Op-amp:** Ideal, TL072, LM358, NE5532, LM741 (open-loop gain, output swing, slew rate, gain-bandwidth and input offset, so an LM358 visibly slews where a TL072 does not), and the pedal ones: JRC4558 (the Tube Screamer's), LM308 (the RAT's, slewing at 0.3 V/µs), CA3130, CA3140, TL074, TL064, OPA2134, LM833; and those of Eurorack modules: NJM2068 (4ms'), OPA1652, OPA2171, and on 3.3 V the rail-to-rail MCP6002 and LMV358 that scale CVs into a microcontroller's ADC. An op-amp can swing about half a single supply, as in a 9 V pedal. A model is found by the other names its part goes by: the quad of a dual (TL084, MCP6004, OPA4171), another maker's (NJM4558, V2164) or a newer grade (LME49720); the name kept is the one shown first. Several op-amps can also run their maker's own SPICE model in place of these equations: see [spice.md](spice.md#running-an-op-amp-on-its-makers-model).
- **OTA:** LM13700 or CA3080 (output current I_abc·tanh(V_in / 2V_T), bias pin one or two junctions above V−, output clamps below the supply).
- **Multiplier:** AD633 and MPY634 (out = x·y / 10 V, softly limited), for ring modulators and VCAs.
- **LM3900** Norton amplifier, built from its transistors: its inputs are junctions, and it amplifies the difference of their currents.

## Delays, reverbs and vactrols

- **Bucket-brigade delay line:** MN3207, MN3008, MN3005 (delay = stages / 2·clock), for chorus, flanger and echo. Its clock is either its own, swept by a control voltage, or the one on its clock pin, as on the real chip: then it takes a sample at each clock cycle and moves its buckets along, holding the sample at its end. Driven by an MN3101 or MN3102 clock driver (CP1 and CP2 in antiphase at about 1 / (2.2 R C), R from RX; an LFO through a resistor into RX sweeps it; VGG at 14/15 of the supply), it counts the driver's cycles exactly however long the steps are, so a 500 kHz flanger clock works at an audio step. The MN3011 has six taps (396, 662, 1194, 1726, 2790 and 3328 stages).
- **Digital reverbs:** the FV-1 effects processor with its eight ROM programs (chorus, flange and tremolo with reverb, pitch shift, pitch-echo, test, two plate reverbs after Dattorro), its three pots as Spin assigns them, at 32.768 kHz through clipping converters, with stereo outputs. Spin's code is not published, so the programs are rewritten. The Belton BTDR-2H brick: a spring's sound from delay chips, wet only.
- **Digital echo:** PT2399. The resistance from pin 6 to ground sets the delay, as on the chip: about 11.5 ms per kΩ plus 24 ms, so 31 ms at 600 Ω and 342 ms at 27.6 kΩ, as in its datasheet. Pin 6 is modelled as an internal reference behind about 2.1 kΩ, so a control voltage through a resistor modulates the delay too. The longer the delay, the slower the chip's clock, so its echo gets darker (about 20 kHz of bandwidth at 30 ms, 2.4 kHz at 340 ms) and noisier.
- **Vactrol:** VTL5C3, NSL-32 (an LED and an LDR whose resistance follows the light with separate attack and decay times), for lowpass gates, compressors and opto tremolo; and the H11F1 photo-FET optocoupler, a FET channel under 200 Ω at 16 mA that follows its LED within tens of microseconds.

## Synth chips

Each worked out once per step from its inputs (so they cost almost nothing to simulate):

- **VCO:** AS3340 (CEM3340): one volt per octave with exact tracking, saw, triangle, pulse (width from ±5 V on PW) or sine, PolyBLEP-smoothed so high notes do not alias.
- **Function generators:** XR2206 (sine or triangle and square at 1 / (R C), amplitude modulation on its AM input), ICL8038 and LM566, the frequency set by the timing current as on the chips.
- **VCF:** AS3320 (CEM3320), SSM2044, IR3109 (Roland's): four-pole 24 dB/octave low-pass with soft saturation, one volt per octave, resonance up to self-oscillation.
- **Envelope:** AS3310 (CEM3310): ADSR with gate and retrigger inputs and analog-style exponential curves (attack reaches the peak in the attack time; decay and release go nine tenths of the way in theirs).
- **VCA:** SSM2164 (exponential, −33 mV/dB) or linear (unity gain at 5 V).
- **Sample and hold:** clocked (samples on each rising edge) or LF398 (tracks while high, holds while low, with droop).
- **Comparator:** LM393 (pulled up to 5 V), LM311 (±12 V), with hysteresis.
- **Clock divider:** CD4013 (÷2, a sub-oscillator), CD4017 carry out (÷10), CD4040 (÷16), with a reset input.
- **Noise:** white, or the MM5837's 17-bit shift register, as in drum machines.

## Tubes and transformers

Tubes use Norman Koren's equations (smooth, fitted to the published curves) and the capacitances between their electrodes (so a 12AX7 stage rolls off its top end through the Miller effect as a real one does):

- **Triode:** 12AX7 (ECC83), 12AT7, 12AU7, ECC88. The grid draws current above the cathode, so an overdriven stage biases itself as in a guitar amp.
- **Pentode:** 6L6GC, EL34, with their screen grids.

**Transformer:** primary inductance, turns ratio, coupling (leakage) and winding resistances; output (8 kΩ : 8 Ω), mains (230 V : 12 V) and interstage (1 : 2) presets. It blocks DC, and its low end falls off with the primary inductance.

## Diodes and transistors

- **Diodes:** 1N4148, 1N4001, 1N34A and OA90 (germanium), BAT41, 1N5817, 1N5819 and BAT54 (Schottky; the BAT54S is two in series, the clamp on Eurorack inputs).
- **Zener:** a plain 5.1 V one and the LM4040 precision shunt references (2.5 V and 10 V), their voltage at 100 µA held within 10 mV up to 15 mA.
- **Transistors:** 2N3904, BC547C, 2N5088, 2N5089, MPSA18, 2N2222, BC549C, BC108, 2N3906, AC128, NKT275 and OC44 (germanium), the matched SSM2212, SSM2220 and CA3046.
- **JFETs:** J113 and 2SK30A; N-JFET 2N5457, J201, 2N3819.
- **MOSFETs:** 2N7000, BS170 and BS250.

Junctions have SPICE's capacitances: each diode's, LED's and transistor junction's depletion capacitance, which falls as it is reverse biased, and the charge a forward current stores for its transit time, which a 1N4001 must give back before it blocks, and which makes a BC108's collector roll off its top end through the Miller effect. The real parts carry their datasheet values. All of them follow the circuit's [temperature](guide.md#simulating).

## CMOS logic and converters

- **555:** NE555, TLC555.
- **Schmitt inverter:** one gate of a CD40106 or 74HC14.
- **Analog switch:** one switch of a CD4066 or DG411.
- **Unbuffered inverter:** one inverter of a CD4069UB or CD4049UB, modelled as its two transistors. Biased by a feedback resistor it is the CMOS amplifier of fuzz pedals and preamps: a gain of about 25 at 9 V, clipping softly at the rails.

CMOS logic, with the supply hidden like the 40106's and set in the inspector:

- **Logic gate:** one gate of a CD4093 (Schmitt NAND, for gated oscillators), CD4011 (NAND), CD4001 (NOR), CD4081 (AND), CD4071 (OR), CD4070 (XOR), CD4077 (XNOR), 74HC132, 74HC00 or 74HC86.
- **D flip-flop:** one half of a CD4013, with set and reset.
- **Decade counter:** CD4017 or 74HC4017, with its ten decoded outputs, clock inhibit and carry out.
- **Binary counter:** CD4040 or 74HC4040, twelve stages, counting on the falling edge.
- **Analog multiplexer:** CD4051 or 74HC4051 (eight channels).
- **Analog selector:** one switch of a CD4053 or 74HC4053 (two channels).
- **Shift register:** one half of a CD4015, or a 74HC595 with its output latch and enable. The **74HC165** parallel-in shift register is described with the STM32s in [microcontrollers.md](microcontrollers.md#converters-and-bus-parts-on-the-stm32s).
- **SPI DAC:** MCP4921 (12 bits). Write 0x3000 plus the code with CS low and OUT goes to VREF × code / 4096. It shifts SDI in on SCK's rising edges and latches the word when CS rises, with LDAC low. The MCP4822 has two, A and B (bit 15), and its own 2.048 V reference.
- **SPI ADC:** MCP3008, eight channels of 10 bits, and the MCP3208 (and the four-channel MCP3204) of 12 bits, as Mutable Instruments' modules read their CVs, the same frame with two more bits. After a start bit, single-ended or differential and the channel, it samples the input and answers on DOUT, a null bit and then the code, bit by bit as the clock runs.
- **I²C DAC:** MCP4725 at 0x60 (0x61 with A0 high), in fast mode or with the write-DAC command, acknowledging each byte by holding SDA low.
- **I²S audio DAC:** PCM5102, 16 to 32 bits a sample, reading each channel's word one BCK after LRCK changes, 2.1 V RMS at full scale about ground.
- The ADC and the I²C DAC answer within a transfer: a microcontroller calls back as it logs each change to their pins, so they move on at once, and what they drive back (a DOUT bit, an acknowledge) is what the chip reads from then on.
- **Phase-locked loop:** CD4046 or 74HC4046. Its VCO runs from fMin to fMax as VCO IN goes from 0 V to the supply. Phase comparator 1 is an XOR. Phase comparator 2 is the edge-triggered phase-frequency detector, driving high or low or letting its output go, so the loop filter holds while the loop is locked.
- Plain CMOS inputs switch at half the supply, Schmitt inputs at their two thresholds. Outputs drive towards the supply or ground through their output resistance. The multiplexers connect the selected channel through their on resistance.

The audio codecs, CV DACs, LED drivers (PCA9685, TLC5947) and I²C EEPROMs that firmware drives are described in [microcontrollers.md](microcontrollers.md#converters-and-bus-parts-on-the-stm32s).

## Audio parts

From the microphone to the speaker: the library's **Audio** section, each part a real chip or transducer chosen in the **Model** menu, simulated as the circuit inside it (so it exports to SPICE and lays out on the breadboard like any other part).

- **Microphones:** dynamic (SM58 and SM7B types, with their source impedance, speaking a synthesized voice), large- and small-diaphragm condensers that need 48 V phantom power through 6.81 kΩ per leg, and electret capsules with their JFET inside, biased through a resistor.
- **Guitar pickups** (single coil, humbucker, P-90, hot humbucker) are an inductance and resistance with the coil's capacitance, so a cable's capacitance and the volume pot shape their tone as on a real guitar.
- **Mic preamps:** SSM2019, THAT1510, THAT1512 and INA217 instrumentation amplifiers, the gain set by one resistor between RG1 and RG2, with their input noise. Low-noise op-amps for discrete preamps and line stages: NE5534, OPA1612, LM4562.
- **Balanced lines:** INA134, THAT1240 and THAT1246 receivers and DRV134 and THAT1646 drivers, and an XLR cable that picks up 50 or 60 Hz hum on both legs, slightly unequally, so a receiver's common-mode rejection can be heard working (or a single-ended input heard failing).
- **Headphone and power amps:** NJM4556 and TPA6120 headphone drivers, the LM386, and TDA2030, LM1875 and LM3886 power amps with their output swing and slew rate.
- **Speaker:** Thiele–Small models (full-range, guitar, woofer, 32 Ω and 300 Ω headphones): its impedance rises at its resonance and with its voice coil's inductance, as an amplifier sees it. Its **full scale** sets the voltage that plays at full volume ([guide.md](guide.md#sound)).
- **Dynamics:** the THAT2180 VCA (−6.1 mV/dB), the THAT2252 RMS detector (+6.1 mV/dB, so the two make a compressor with no scaling between them), the THAT4301 with both and a spare op-amp, peak and average detectors, the NE570/SA571 compander, and the SSM2166 mic preamp, which compresses above its rotation point and gates below its threshold.
- **Ring modulators and mixers:** the MC1496 balanced modulator and the SA612 mixer with its oscillator, both built transistor by transistor, and centre-tapped transformers for a diode ring.
- **Footswitch:** the 3PDT footswitch of true-bypass pedals: three poles, each joined to its bypass or its effect throw; click it like a switch.
- **Switched jack:** the switched jack of Eurorack modules (a Thonkiconn): unplugged, its tip rests on its normal lug, so an input reads what it is normalled to; click it to plug a cable in, and the tip joins the cable's plug, which a wire takes to another jack's plug as a patch cable does.
- **Voltage regulators:** LM7805, 78L05, LM7812, the negative 79L05 and LM7912, the LM1117-3.3 of a microcontroller's supply, and the adjustable LM317 and LM337 (1.25 V between OUT and ADJ, set by a divider). Each is simulated as an error amplifier holding its output at the reference through a pass transistor, which drops out at its dropout below the input, with its quiescent current drawn from the input; there is no current limit or thermal shutdown.
- **Tone:** the LM1036 DC-controlled volume, bass and treble chip; passive tone stacks, the Baxandall, a gyrator graphic EQ and a state-variable parametric EQ are in the [examples](examples.md#mics-dynamics--eq), built from parts.
- **Spring reverb:** long and short tanks, driven at 8 Ω, 150 Ω or 1475 Ω: dispersive springs whose drips and twang come from chains of all-pass filters, as in the real tank's delay lines.
- **Meters:** a VU meter (+4 dBu or −10 dBV, with the needle's 300 ms ballistics) and a peak programme meter, drawn as a needle on the schematic and the front panel, and the LM3914, LM3915 and LM3916 bar-graph drivers lighting ten LEDs.
