# Examples

JSpice comes with 94 example circuits. Open them from the **Examples** window (**File ▸ New from Example…**, **Help ▸ Example Gallery**, the **Examples** row at the top of the library, or **Browse All Examples…** in an empty window), where they are filed by the categories below, can be searched by title, summary or category, and are badged for sound, knobs, a keyboard or a microcontroller. An example opens in a new window. An empty window offers a few of them by interest, and the ⌘K palette finds them by name too. Agents list them with `list_examples` and open one with `load_example` ([mcp.md](mcp.md)).

"(sound)" means the example plays through a speaker: turn on **Sound** in the toolbar. Microcontroller examples come with their firmware built in, so they run without Chip Support.

- [Pedals & Effects](#pedals--effects)
- [Synth](#synth)
- [Amplifiers & Tubes](#amplifiers--tubes)
- [Mics, Dynamics & EQ](#mics-dynamics--eq)
- [Logic & Sequencers](#logic--sequencers)
- [Microcontrollers](#microcontrollers)
- [Basics](#basics)
- [Memristors](#memristors)

## Pedals & Effects

- **Tube Screamer overdrive** (sound): one half of a JRC4558 amplifying the frequencies above about 720 Hz into two 1N4148s, and the other half the active TONE control.
- **RAT distortion** (sound): an LM308 with a gain of over 2000 in the treble, slewing at 0.3 V/µs, two 1N4148s clipping hard to ground and a FILTER knob.
- **Diode-clipper overdrive** (sound): a TL072 gain stage into two 1N4148s to ground.
- **Fuzz Face** (sound): the classic two-transistor fuzz (silicon, BC108), on a sine.
- **Fuzz Face on a guitar riff** (sound): the Fuzz Face played by a recorded guitar riff from an audio input part; choose your own sound file, or the Mac's live input.
- **Fuzz Face with a humbucker** (sound): a guitar pickup into the fuzz, whose low input impedance loads the pickup and takes its treble.
- **CMOS fuzz** (sound): a two-stage CD4049UB fuzz, two unbuffered inverters biased as amplifiers.
- **OTA tremolo** (sound): an LM13700 VCA whose gain a slow LFO sweeps.
- **H11F1 opto tremolo** (sound): an H11F1 photo-FET optocoupler shunting the guitar as a 5 Hz LFO lights its LED.
- **BBD chorus** (sound): an MN3207 bucket brigade swept by a 0.7 Hz LFO, mixed with the dry signal.
- **BBD chorus with its clock driver** (sound): an MN3207 clocked by its MN3102 clock driver at about 80 kHz, a delay of about 5 to 8.5 ms.
- **PT2399 echo** (sound): a PT2399 echo with TIME and REPEATS knobs.
- **MN3011 multi-tap echo** (sound): an MN3011 clocked by an MN3101, its six taps giving the guitar back after 12 to 99 ms.
- **FV-1 reverb** (sound): an FV-1 running its plate reverb program, with TIME, TONE and LOW CUT pots.
- **Belton brick reverb** (sound): a Belton BTDR-2H brick, wet only, mixed with the dry guitar by a LEVEL pot.
- **Spring reverb** (sound): an op-amp driving a long spring tank, and a MIX knob.
- **Ring modulator** (sound): an AD633 multiplying two tones.
- **Ring modulator: MC1496** (sound): a guitar riff times a 440 Hz carrier in an MC1496 built transistor by transistor.
- **Ring modulator: SA612** (sound): the SA612 radio mixer as a ring modulator.
- **Diode ring modulator** (sound): four OA90 germanium diodes between two centre-tapped transformers.
- **Bode frequency shifter** (sound): two all-pass chains of TL074s and two AD633s move every frequency of a guitar riff up by 30 Hz.
- **PLL octave up** (sound): a CD4046 locked to twice its input through a CD4013.
- **3PDT true bypass** (sound): a true-bypass pedal's footswitch switching an op-amp clipper and its LED.

## Synth

- **Synth voice: VCO, VCF, VCA**: a full synth voice, the keyboard VCO through the resonant filter and a VCA, one envelope opening both. Play it from the keyboard.
- **Mono synth: VCO, envelope and VCA**: the keyboard VCO's square wave through an LM13700 VCA opened by an attack–release envelope (the gate charges it through a DG411 switch).
- **Keyboard VCO (1 V/octave)**: a real 1 V/octave oscillator, a PNP exponential converter and an LM13700 triangle core.
- **LM13700 filter** (sound): an LM13700 resonant filter, a 12 dB/octave state-variable filter with cutoff and resonance pots, on a square wave.
- **Sequenced bassline** (sound): the synth voice playing a sequenced bassline from the step sequencer.
- **Chip synth: AS3340, AS3320, AS3310** (sound): a chip synth voice, two AS3340s and a CD4013 sub-oscillator through an AS3320 and a VCA, an AS3310 opening both, playing an arpeggio.
- **Random notes: sample and hold** (sound): noise through a clocked sample and hold into a VCO.
- **Vactrol lowpass gate** (sound): a VTL5C3 vactrol opening a tone on each gate pulse.
- **Comparator PWM** (sound): an LM311 comparing a triangle with a slow sine.
- **Wind: filtered noise** (sound): noise through the resonant LM13700 filter.
- **Triangle and square LFO**: two TL072s, an integrator and a Schmitt trigger.
- **OTA voltage-controlled amplifier**: an OTA VCA (LM13700) whose bias a slow control voltage sets.
- **Sample and hold**: a CD4066 switch and a TL072 buffer.
- **XR2206 function generator** (sound): an XR2206 generator, its FREQUENCY pot setting f = 1 / (R C).

## Amplifiers & Tubes

- **Single-ended tube amp** (sound): a 12AX7 into a 6L6GC and an output transformer.
- **Fender and Marshall tone stacks**: the two passive tone stacks side by side, with frequency-response scopes.
- **LM386 into a loudspeaker** (sound): an LM386 amp into a 4" loudspeaker modelled by its Thiele-Small parameters.
- **TDA2030 power amp** (sound): a TDA2030 power amp into a 12" guitar speaker.
- **Headphone amp: NJM4556** (sound): a headphone amp into 32 Ω headphones.
- **LM3900 Norton amplifier** (sound): an LM3900 amplifier built transistor by transistor.

## Mics, Dynamics & EQ

- **Mic preamp: SSM2019** (sound): a dynamic mic into an SSM2019 preamp.
- **Condenser mic on phantom power** (sound): a condenser on 48 V phantom power into a THAT1510.
- **Electret mic preamp: NE5534** (sound): an electret preamp.
- **SSM2166 mic preamp with compression** (sound): an SSM2166 voice, compressed above its rotation point and gated below its threshold.
- **Balanced line rejects hum**: a balanced line through a humming cable, against an unbalanced one.
- **Compressor: THAT2180 and THAT2252** (sound): a feed-forward compressor.
- **THAT4301 compressor** (sound): a THAT4301 compressor, the dbx way.
- **Opto compressor** (sound): an NSL-32 opto cell shunting the signal, the LA-2A idea.
- **NE570 compander** (sound): an NE570 compander.
- **Noise gate** (sound): a noise gate on a voice over a hiss.
- **Baxandall tone control**: a Baxandall.
- **Graphic EQ with gyrators**: a graphic EQ of five bands.
- **Parametric EQ band (state-variable)**: a parametric EQ band.
- **LM1036 tone control chip**: an LM1036 tone control.
- **LED level meter: LM3915**: an LM3915 level meter, beside a VU meter.

## Logic & Sequencers

- **Baby 10 sequencer, four steps** (sound): a four-step Baby 10 (CD4017).
- **CMOS 8-step sequencer** (sound): an 8-step sequencer, a CD4093 clock, a CD4040 counter and a CD4051 picking one of eight knobs for a VCO.
- **Shift-register sequencer** (sound): a 74HC595 sequencer clocked by a 74HC14.
- **CMOS drone** (sound): a CMOS drone, CD4093 oscillators, a CD4070 XOR and a CD4013 sub-octave.
- **555 beeper** (sound): a 555 at about 460 Hz into a speaker.
- **Schmitt oscillator tone** (sound): one gate of a 40106 in the audio range; turn the pot to change the pitch.
- **555 LED flasher**: the classic astable 555.
- **Schmitt trigger oscillator**: a Schmitt trigger oscillator (40106) blinking an LED.

## Microcontrollers

- **Arduino: Blink**: an ATmega328P running Blink.
- **Arduino: PWM fade**: a PWM fade through an RC filter.
- **Arduino: knob and LED**: knob and LED with serial output.
- **Arduino: melody** (sound): melody on a speaker.
- **Arduino: SPI DAC through a filter** (sound): a sawtooth arpeggio sent sample by sample to an MCP4921 DAC over SPI and through a filter.
- **Arduino: two LFOs from an MCP4822**: an Arduino with an MCP4822's two LFOs.
- **Arduino: SPI ADC to I²C DAC**: an Arduino reading an MCP3008 and writing an MCP4725.
- **Arduino Mega: bar graph**: a bar graph from a pot.
- **ATtiny85: dimmer**: an ATtiny85 dimmer and a breathing LED.
- **Raspberry Pi Pico: knob and LED**: knob and LED with 12-bit PWM and USB serial.
- **Raspberry Pi Pico: melody** (sound): a melody from PIO.
- **Pico: I²S audio DAC** (sound): a Pico playing a sine through a PCM5102 over I²S.

## Basics

- **LED and switch**: click the switch to turn the LED on and off.
- **Voltage divider**: two resistors split 10 V in the ratio 1 : 2.
- **Capacitor charging**: close the switch and watch the capacitor charge, in real time.
- **RC low-pass filter**: a 100 Hz square wave rounded off by an RC filter, in slow motion.
- **LC oscillator**: a charged capacitor and a coil swap energy at 50 Hz.
- **Half-wave rectifier**: a diode and a capacitor turn 60 Hz AC into DC.
- **Zener regulator**: a Zener diode holds the output at 5.1 V.
- **Light dimmer**: a potentiometer dims the LED through a transistor.
- **Blinking LEDs**: an astable multivibrator, two transistors taking turns.
- **Transistor switch**: a MOSFET lets a small switch current control an LED.
- **CMOS inverter**: two transistors invert the input.
- **Op-amp amplifier**: an inverting amplifier with a gain of −10.
- **Op-amp stability: driving a cable**: a TL072 driving 100 nF of cable through 100 Ω, about 6° of phase margin at the loop probe ([guide.md](guide.md#scopes-and-analyses)).
- **Blocks: two tone stages** (sound): one tone stage saved as a block and used twice, each copy with its own knob.

## Memristors

- **Memristor hysteresis**: a 1 Hz sine traces a memristor's pinched I–V loop.
- **Memristor programming**: each pulse lowers the memristor's resistance a little.
