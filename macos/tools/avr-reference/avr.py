"""Reference AVR emulator (ATmega328P, ATmega2560, ATtiny85), written to be ported line by line to Swift
(CircuitKit/AVR.swift and AVRVariant.swift).

Data space: r0-r31 at 0x00-0x1F, I/O at 0x20-0x5F (IN/OUT address + 0x20), extended I/O after it, then SRAM.
A chip is described by a Variant (memories, ports and pins, timers, USARTs, ADC, interrupts); the CPU and the
peripherals are the same for all of them.
"""

C, Z, N, V, S, H, T, I = 1, 2, 4, 8, 16, 32, 64, 128
SPL, SPH, SREG = 0x5D, 0x5E, 0x5F
RAMPZ, EIND = 0x5B, 0x5C


class TimerSpec:
    """kind: 'std8' (8-bit, two compare units), 'std16' (16-bit, two or three units and input capture) or 'tiny1'
    (the ATtiny85's 8-bit timer 1, with OCR1C as TOP)"""

    def __init__(self, kind, tccra, tccrb, tcnt, ocr, timsk, tifr, ovf_bit, comp_bits, ovf_vector, comp_vectors,
                 prescalers, pins, icr=None, capt_bit=None, capt_vector=None, ocr_top=None, complements=None):
        self.kind, self.tccra, self.tccrb, self.tcnt, self.ocr = kind, tccra, tccrb, tcnt, ocr
        self.timsk, self.tifr, self.ovf_bit, self.comp_bits = timsk, tifr, ovf_bit, comp_bits
        self.ovf_vector, self.comp_vectors = ovf_vector, comp_vectors
        self.prescalers, self.pins = prescalers, pins
        self.icr, self.capt_bit, self.capt_vector = icr, capt_bit, capt_vector
        self.ocr_top = ocr_top          # tiny1: OCR1C
        self.complements = complements  # tiny1: the inverted output pins (!OC1A, !OC1B)


class UartSpec:
    def __init__(self, base, rx_vector, udre_vector, tx_vector, rx_pin, tx_pin):
        # UCSRnA, B, C at base, base+1, base+2; UBRRnL, H at base+4, base+5; UDRn at base+6
        self.ucsra, self.ucsrb, self.ucsrc = base, base + 1, base + 2
        self.ubrrl, self.ubrrh, self.udr = base + 4, base + 5, base + 6
        self.rx_vector, self.udre_vector, self.tx_vector = rx_vector, udre_vector, tx_vector
        self.rx_pin, self.tx_pin = rx_pin, tx_pin


class Variant:
    pass


STD_PRESCALERS = [0, 1, 8, 64, 256, 1024, 0, 0]
TIMER2_PRESCALERS = [0, 1, 8, 32, 64, 128, 256, 1024]
# ADC channel table entries: a pin index, or one of these
ADC_GROUND, ADC_BANDGAP = -1, -2


def _atmega328p():
    v = Variant()
    v.name, v.clock = 'atmega328p', 16_000_000
    v.flash_words, v.data_size, v.eeprom_size = 16384, 0x900, 1024
    v.io_end, v.pc_bytes, v.vector_words = 0x100, 2, 2
    # PINx of ports B, C, D (DDRx and PORTx follow)
    v.ports = [0x23, 0x26, 0x29]
    # Uno pins: D0-D7 = PD0-7, D8-D13 = PB0-5, A0-A5 = PC0-5
    v.pins = [(2, b) for b in range(8)] + [(0, b) for b in range(6)] + [(1, b) for b in range(6)]
    v.timers = [
        TimerSpec('std8', 0x44, 0x45, 0x46, [0x47, 0x48], 0x6E, 0x35, 1, [2, 4], 16, [14, 15], STD_PRESCALERS, [6, 5]),
        TimerSpec('std16', 0x80, 0x81, 0x84, [0x88, 0x8A], 0x6F, 0x36, 1, [2, 4], 13, [11, 12], STD_PRESCALERS, [9, 10],
                  icr=0x86, capt_bit=0x20, capt_vector=10),
        TimerSpec('std8', 0xB0, 0xB1, 0xB2, [0xB3, 0xB4], 0x70, 0x37, 1, [2, 4], 9, [7, 8], TIMER2_PRESCALERS, [11, 3]),
    ]
    v.uarts = [UartSpec(0xC0, 18, 19, 20, 0, 1)]
    v.adc = dict(admux=0x7C, adcsra=0x7A, adcsrb=0x7B, adcl=0x78, adch=0x79, vector=21, mux5=False, tiny=False, mux_mask=0x0F)
    v.adc_channels = {c: 14 + c for c in range(6)}
    v.adc_channels.update({14: ADC_BANDGAP, 15: ADC_GROUND})
    v.adc_references = {0: None, 1: None, 3: 1.1}  # REFS1:0 -> volts (None: the supply)
    # external interrupts: (pin, control register, shift, mask register, bit, flag register, bit, vector)
    v.ext_ints = [(2, 0x69, 0, 0x3D, 1, 0x3C, 1, 1), (3, 0x69, 2, 0x3D, 2, 0x3C, 2, 2)]
    # pin change interrupts: (control register, bit, flag register, bit, mask register, pins by bit, vector)
    v.pcints = [(0x68, 1, 0x3B, 1, 0x6B, [8, 9, 10, 11, 12, 13, -1, -1], 3),
                (0x68, 2, 0x3B, 2, 0x6C, [14, 15, 16, 17, 18, 19, -1, -1], 4),
                (0x68, 4, 0x3B, 4, 0x6D, [0, 1, 2, 3, 4, 5, 6, 7], 5)]
    v.eeprom_regs = (0x3F, 0x40, 0x41, 0x42)
    v.clear_on_write = [0x35, 0x36, 0x37, 0x3B, 0x3C]
    v.mask_registers = [0x6E, 0x6F, 0x70, 0x3D, 0x68]
    return v


def _atmega2560():
    v = Variant()
    v.name, v.clock = 'atmega2560', 16_000_000
    v.flash_words, v.data_size, v.eeprom_size = 131072, 0x2200, 4096
    v.io_end, v.pc_bytes, v.vector_words = 0x200, 3, 2
    # PINx of ports A-L (no I)
    names = 'ABCDEFGHJKL'
    v.ports = [0x20, 0x23, 0x26, 0x29, 0x2C, 0x2F, 0x32, 0x100, 0x103, 0x106, 0x109]
    mega = ['E0', 'E1', 'E4', 'E5', 'G5', 'E3', 'H3', 'H4', 'H5', 'H6', 'B4', 'B5', 'B6', 'B7', 'J1', 'J0', 'H1', 'H0',
            'D3', 'D2', 'D1', 'D0', 'A0', 'A1', 'A2', 'A3', 'A4', 'A5', 'A6', 'A7', 'C7', 'C6', 'C5', 'C4', 'C3', 'C2',
            'C1', 'C0', 'D7', 'G2', 'G1', 'G0', 'L7', 'L6', 'L5', 'L4', 'L3', 'L2', 'L1', 'L0', 'B3', 'B2', 'B1', 'B0',
            'F0', 'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'K0', 'K1', 'K2', 'K3', 'K4', 'K5', 'K6', 'K7']
    v.pins = [(names.index(p[0]), int(p[1])) for p in mega]
    pin = {p: i for i, p in enumerate(mega)}
    v.timers = [
        TimerSpec('std8', 0x44, 0x45, 0x46, [0x47, 0x48], 0x6E, 0x35, 1, [2, 4], 23, [21, 22], STD_PRESCALERS,
                  [pin['B7'], pin['G5']]),
        TimerSpec('std16', 0x80, 0x81, 0x84, [0x88, 0x8A, 0x8C], 0x6F, 0x36, 1, [2, 4, 8], 20, [17, 18, 19],
                  STD_PRESCALERS, [pin['B5'], pin['B6'], pin['B7']], icr=0x86, capt_bit=0x20, capt_vector=16),
        TimerSpec('std8', 0xB0, 0xB1, 0xB2, [0xB3, 0xB4], 0x70, 0x37, 1, [2, 4], 15, [13, 14], TIMER2_PRESCALERS,
                  [pin['B4'], pin['H6']]),
        TimerSpec('std16', 0x90, 0x91, 0x94, [0x98, 0x9A, 0x9C], 0x71, 0x38, 1, [2, 4, 8], 35, [32, 33, 34],
                  STD_PRESCALERS, [pin['E3'], pin['E4'], pin['E5']], icr=0x96, capt_bit=0x20, capt_vector=31),
        TimerSpec('std16', 0xA0, 0xA1, 0xA4, [0xA8, 0xAA, 0xAC], 0x72, 0x39, 1, [2, 4, 8], 45, [42, 43, 44],
                  STD_PRESCALERS, [pin['H3'], pin['H4'], pin['H5']], icr=0xA6, capt_bit=0x20, capt_vector=41),
        TimerSpec('std16', 0x120, 0x121, 0x124, [0x128, 0x12A, 0x12C], 0x73, 0x3A, 1, [2, 4, 8], 50, [47, 48, 49],
                  STD_PRESCALERS, [pin['L3'], pin['L4'], pin['L5']], icr=0x126, capt_bit=0x20, capt_vector=46),
    ]
    v.uarts = [UartSpec(0xC0, 25, 26, 27, pin['E0'], pin['E1']), UartSpec(0xC8, 36, 37, 38, pin['D2'], pin['D3']),
               UartSpec(0xD0, 51, 52, 53, pin['H0'], pin['H1']), UartSpec(0x130, 54, 55, 56, pin['J0'], pin['J1'])]
    v.adc = dict(admux=0x7C, adcsra=0x7A, adcsrb=0x7B, adcl=0x78, adch=0x79, vector=29, mux5=True, tiny=False, mux_mask=0x1F)
    v.adc_channels = {c: 54 + c for c in range(8)}
    v.adc_channels.update({0x20 + c: 62 + c for c in range(8)})
    v.adc_channels.update({0x1E: ADC_BANDGAP, 0x1F: ADC_GROUND})
    v.adc_references = {0: None, 1: None, 2: 1.1, 3: 2.56}
    v.ext_ints = [(pin['D0'], 0x69, 0, 0x3D, 1, 0x3C, 1, 1), (pin['D1'], 0x69, 2, 0x3D, 2, 0x3C, 2, 2),
                  (pin['D2'], 0x69, 4, 0x3D, 4, 0x3C, 4, 3), (pin['D3'], 0x69, 6, 0x3D, 8, 0x3C, 8, 4),
                  (pin['E4'], 0x6A, 0, 0x3D, 16, 0x3C, 16, 5), (pin['E5'], 0x6A, 2, 0x3D, 32, 0x3C, 32, 6)]
    v.pcints = [(0x68, 1, 0x3B, 1, 0x6B, [pin['B%d' % b] for b in range(8)], 9),
                (0x68, 2, 0x3B, 2, 0x6C, [pin['E0'], pin['J0'], pin['J1'], -1, -1, -1, -1, -1], 10),
                (0x68, 4, 0x3B, 4, 0x6D, [pin['K%d' % b] for b in range(8)], 11)]
    v.eeprom_regs = (0x3F, 0x40, 0x41, 0x42)
    v.clear_on_write = [0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C]
    v.mask_registers = [0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, 0x3D, 0x68]
    return v


def _attiny85():
    v = Variant()
    v.name, v.clock = 'attiny85', 8_000_000
    v.flash_words, v.data_size, v.eeprom_size = 4096, 0x260, 512
    v.io_end, v.pc_bytes, v.vector_words = 0x60, 2, 1
    v.ports = [0x36]
    v.pins = [(0, b) for b in range(6)]
    v.timers = [
        # TIFR/TIMSK bits: OCF1A 6, OCF1B 5, OCF0A 4, OCF0B 3, TOV1 2, TOV0 1
        TimerSpec('std8', 0x4A, 0x53, 0x52, [0x49, 0x48], 0x59, 0x58, 2, [16, 8], 5, [10, 11], STD_PRESCALERS, [0, 1]),
        TimerSpec('tiny1', 0x50, 0x4C, 0x4F, [0x4E, 0x4B], 0x59, 0x58, 4, [64, 32], 4, [3, 9],
                  [0] + [1 << k for k in range(15)], [1, 4], ocr_top=0x4D, complements=[0, 3]),
    ]
    v.uarts = []
    v.adc = dict(admux=0x27, adcsra=0x26, adcsrb=0x23, adcl=0x24, adch=0x25, vector=8, mux5=False, tiny=True, mux_mask=0x0F)
    v.adc_channels = {0: 5, 1: 2, 2: 4, 3: 3, 12: ADC_BANDGAP, 13: ADC_GROUND}
    v.adc_references = {0: None, 1: None, 2: 1.1, 3: None, 6: 2.56, 7: 2.56}  # REFS2:0
    v.ext_ints = [(2, 0x55, 0, 0x5B, 64, 0x5A, 64, 1)]
    v.pcints = [(0x5B, 32, 0x5A, 32, 0x35, [0, 1, 2, 3, 4, 5, -1, -1], 2)]
    v.eeprom_regs = (0x3C, 0x3D, 0x3E, 0x3F)
    v.clear_on_write = [0x58, 0x5A]
    v.mask_registers = [0x59, 0x5B]
    return v


VARIANTS = {'atmega328p': _atmega328p(), 'atmega2560': _atmega2560(), 'attiny85': _attiny85()}


class Timer:
    def __init__(self, avr, spec):
        self.avr, self.spec = avr, spec
        self.units = len(spec.ocr)
        self.reset()

    def reset(self):
        self.count = 0
        self.down = False
        self.accumulator = 0
        self.ocr = [0] * self.units          # in use
        self.ocr_buffer = [0] * self.units   # written, copied at TOP or BOTTOM in PWM modes
        self.icr = 0
        self.top_c = 0xFF                    # tiny1: OCR1C
        self.output = [False] * self.units   # OCxn pin states
        self.temp = 0                        # 16-bit: the shared high byte

    # -- configuration

    def control_a(self):
        return self.avr.data[self.spec.tccra]

    def clock_select(self):
        if self.spec.kind == 'tiny1':
            return self.avr.data[self.spec.tccra] & 0x0F
        return self.avr.data[self.spec.tccrb] & 7

    def mode(self):
        """(top, kind, source): kind 'normal', 'ctc', 'fast', 'phase'; source 'fixed', 'ocra', 'icr'"""
        d = self.avr.data
        sp = self.spec
        if sp.kind == 'tiny1':
            pwm = d[sp.tccra] & 0x40 or d[sp.tccrb] & 0x40
            if pwm: return self.top_c, 'fast', 'ocrc'
            if d[sp.tccra] & 0x80: return self.top_c, 'ctc', 'ocrc'
            return 0xFF, 'normal', 'fixed'
        wgm = (d[sp.tccra] & 3) | ((d[sp.tccrb] >> 1) & (0xC if sp.kind == 'std16' else 0x4))
        if sp.kind == 'std8':
            table = {1: (0xFF, 'phase', 'fixed'), 2: (0, 'ctc', 'ocra'), 3: (0xFF, 'fast', 'fixed'),
                     5: (0, 'phase', 'ocra'), 7: (0, 'fast', 'ocra')}
            top, kind, source = table.get(wgm, (0xFF, 'normal', 'fixed'))
        else:
            table = {1: (0xFF, 'phase', 'fixed'), 2: (0x1FF, 'phase', 'fixed'), 3: (0x3FF, 'phase', 'fixed'),
                     4: (0, 'ctc', 'ocra'), 5: (0xFF, 'fast', 'fixed'), 6: (0x1FF, 'fast', 'fixed'),
                     7: (0x3FF, 'fast', 'fixed'), 8: (0, 'phase', 'icr'), 9: (0, 'phase', 'ocra'),
                     10: (0, 'phase', 'icr'), 11: (0, 'phase', 'ocra'), 12: (0, 'ctc', 'icr'), 14: (0, 'fast', 'icr'),
                     15: (0, 'fast', 'ocra')}
            top, kind, source = table.get(wgm, (0xFFFF, 'normal', 'fixed'))
        if source == 'ocra': top = self.ocr[0]
        elif source == 'icr': top = self.icr
        return top, kind, source

    def compare_output(self, unit):
        """COMnx1:COMnx0: A in bits 7:6, B in 5:4, C in 3:2 of TCCRnA (tiny1: A in TCCR1 5:4, B in GTCCR 5:4)"""
        d = self.avr.data
        if self.spec.kind == 'tiny1':
            return (d[self.spec.tccra if unit == 0 else self.spec.tccrb] >> 4) & 3
        return (d[self.spec.tccra] >> (6 - 2 * unit)) & 3

    def pwm_unit(self, unit):
        """tiny1: whether the unit is in PWM mode (PWM1A, PWM1B)"""
        d = self.avr.data
        return bool(d[self.spec.tccra if unit == 0 else self.spec.tccrb] & 0x40)

    def write_ocr(self, unit, value):
        self.ocr_buffer[unit] = value
        _, kind, _ = self.mode()
        if kind in ('normal', 'ctc') or self.spec.kind == 'tiny1' or not self.avr.pwm_double_buffered:
            self.ocr[unit] = value

    def flag(self, bit):
        self.avr.data[self.spec.tifr] |= bit
        self.avr.irq_dirty = True

    # -- counting

    def match(self, unit, kind, source):
        com = self.compare_output(unit)
        if com == 0:
            return
        if self.spec.kind == 'tiny1':
            if self.pwm_unit(unit):
                self.output[unit] = com == 3   # cleared on match (set at BOTTOM); COM 3 inverted
            elif com == 1: self.output[unit] = not self.output[unit]
            else: self.output[unit] = com == 3
            return
        if kind in ('normal', 'ctc'):
            if com == 1: self.output[unit] = not self.output[unit]
            else: self.output[unit] = com == 3
        elif kind == 'fast':
            if com == 2: self.output[unit] = False
            elif com == 3: self.output[unit] = True
            elif unit == 0 and source == 'ocra': self.output[0] = not self.output[0]
        else:  # phase correct: cleared counting up, set counting down (non-inverting)
            if com == 2: self.output[unit] = self.down
            elif com == 3: self.output[unit] = not self.down
            elif unit == 0 and source == 'ocra': self.output[0] = not self.output[0]

    def tick_tiny1(self):
        top, kind, _ = self.mode()
        old = self.count
        if self.count == top and kind != 'normal':
            self.count = 0
            if kind == 'fast':
                self.flag(self.spec.ovf_bit)
                for unit in range(self.units):
                    com = self.compare_output(unit)
                    if com and self.pwm_unit(unit): self.output[unit] = com != 3
        elif self.count == 0xFF:
            self.count = 0
            self.flag(self.spec.ovf_bit)
        else:
            self.count += 1
        for unit in range(self.units):
            if old == self.ocr[unit]:
                self.flag(self.spec.comp_bits[unit])
                self.match(unit, kind, 'ocrc')

    def tick(self):
        sp = self.spec
        if sp.kind == 'tiny1':
            self.tick_tiny1()
            return
        top, kind, source = self.mode()
        if kind == 'phase':
            if not self.down:
                self.count += 1
                if self.count >= top:
                    self.count = top
                    self.down = True
                    self.ocr = list(self.ocr_buffer)  # double-buffered compare values update at TOP
            else:
                self.count -= 1
                if self.count <= 0:
                    self.count = 0
                    self.down = False
                    self.flag(sp.ovf_bit)  # overflow at BOTTOM
            for unit in range(self.units):
                if self.count == self.ocr[unit]:
                    self.flag(sp.comp_bits[unit])
                    self.match(unit, kind, source)
            return
        old = self.count
        wrapped = False
        if self.count == top and kind in ('ctc', 'fast'):
            self.count = 0
            wrapped = True
            if kind == 'fast':
                self.flag(sp.ovf_bit)
        elif self.count == (0xFF if sp.kind == 'std8' else 0xFFFF):
            self.count = 0
            wrapped = True
            self.flag(sp.ovf_bit)
        else:
            self.count += 1
        if kind == 'fast':
            # the pin changes a timer clock after the counter equals OCR (duty (OCR + 1) / (TOP + 1)), and the
            # change at BOTTOM comes after it: OCR = TOP stays high, OCR = 0 gives a one-clock spike
            for unit in range(self.units):
                if old == self.ocr[unit]:
                    self.flag(sp.comp_bits[unit])
                    self.match(unit, kind, source)
            if wrapped:
                self.ocr = list(self.ocr_buffer)
                for unit in range(self.units):
                    com = self.compare_output(unit)
                    if com == 2: self.output[unit] = True
                    elif com == 3: self.output[unit] = False
            return
        # the flag (and the pin) change on the timer clock after the counter equals OCR
        for unit in range(self.units):
            if old == self.ocr[unit]:
                self.flag(sp.comp_bits[unit])
                self.match(unit, kind, source)

    def advance(self, cycles):
        prescale = self.spec.prescalers[self.clock_select()]
        if prescale == 0:
            return
        self.accumulator += cycles
        while self.accumulator >= prescale:
            self.accumulator -= prescale
            self.tick()


class Uart:
    def __init__(self, avr, spec):
        self.avr, self.spec = avr, spec
        self.output = []
        self.input = []
        self.reset()

    def reset(self):
        d = self.avr.data
        d[self.spec.ucsra] = 0x20  # the transmit buffer starts empty
        d[self.spec.ucsrc] = 0x06
        self.output = []
        self.busy_until = 0
        self.pending = None
        self.receive_next = 0
        # simavr's transmitter (see simavr_mode)
        self.sim_count = 0
        self.sim_pump_at = None
        self.sim_cycles_per_byte = 1600

    def frame_cycles(self):
        d = self.avr.data
        rate = (d[self.spec.ubrrh] << 8 | d[self.spec.ubrrl]) & 0xFFF
        return (8 if d[self.spec.ucsra] & 0x02 else 16) * (rate + 1) * 10

    def append(self, value):
        self.output.append(value)
        if len(self.output) > 32768:
            del self.output[:len(self.output) - 16384]

    def write_data(self, value):
        d = self.avr.data
        a = self.spec.ucsra
        self.avr.irq_dirty = True
        if not self.avr.uart_double_buffered:
            d[a] &= ~0x20
            if d[self.spec.ucsrb] & 0x08:
                self.append(value)
                self.sim_count += 1
                if self.sim_pump_at is None:
                    self.sim_pump_at = self.avr.cycles + self.sim_cycles_per_byte
            return
        if self.busy_until > self.avr.cycles:
            self.pending = value
            d[a] &= ~0x20  # UDRE: the buffer is full
        else:
            self.append(value)
            self.busy_until = self.avr.cycles + self.frame_cycles()
            d[a] |= 0x20
        d[a] &= ~0x40

    def read_data(self):
        d = self.avr.data
        value = d[self.spec.udr]
        d[self.spec.ucsra] &= ~0x80
        self.avr.irq_dirty = True
        return value

    def write_status(self, value):
        d = self.avr.data
        a = self.spec.ucsra
        # only U2X and MPCM are written; writing 1 to TXC clears it
        d[a] = (d[a] & ~0x03 | value & 0x03) & ~(value & 0x40)
        self.avr.irq_dirty = True

    def write_control(self, value):
        d = self.avr.data
        if self.avr.uart_double_buffered:
            d[self.spec.ucsrb] = value
            self.avr.irq_dirty = True
            return
        old = d[self.spec.ucsrb]
        d[self.spec.ucsrb] = value
        if not old & 0x20 and value & 0x20 and value & 0x08 and self.sim_pump_at is None:
            d[self.spec.ucsra] |= 0x20
        if old & 0x08 and not value & 0x08:
            d[self.spec.ucsra] &= ~0x20
        self.avr.irq_dirty = True

    def write_rate_low(self, value):
        d = self.avr.data
        d[self.spec.ubrrl] = value
        rate = (d[self.spec.ubrrh] << 8 | value) & 0xFFF
        self.sim_cycles_per_byte = (rate + 1) * (8 if d[self.spec.ucsra] & 0x02 else 16) * 11

    def needs_update(self):
        return self.busy_until or self.sim_pump_at is not None or (self.input and self.avr.data[self.spec.ucsrb] & 0x10)

    def update(self):
        d = self.avr.data
        a = self.spec.ucsra
        cycles = self.avr.cycles
        if not self.avr.uart_double_buffered:
            while self.sim_pump_at is not None and cycles >= self.sim_pump_at:
                self.simavr_pump()
        elif self.busy_until and cycles >= self.busy_until:
            if self.pending is not None:
                self.append(self.pending)
                self.pending = None
                self.busy_until += self.frame_cycles()
                d[a] |= 0x20
            else:
                self.busy_until = 0
                d[a] |= 0x40  # TXC
            self.avr.irq_dirty = True
        if self.input and d[self.spec.ucsrb] & 0x10 and cycles >= self.receive_next and not d[a] & 0x80:
            d[self.spec.udr] = self.input.pop(0)
            d[a] |= 0x80
            self.receive_next = cycles + self.frame_cycles()
            self.avr.irq_dirty = True

    # simavr's UART, for comparing with it: TXEN on at reset, UDRE cleared when TXEN goes off, a "pump" that raises
    # UDRE once per byte time (11 bits: it counts a parity bit) while bytes are queued or UDRIE is on
    def simavr_pump(self):
        d = self.avr.data
        a = self.spec.ucsra
        when = self.sim_pump_at
        self.sim_pump_at = None
        if self.sim_count:
            if self.sim_count == 1:
                d[a] |= 0x40
            self.sim_count -= 1
        if self.sim_count:
            d[a] &= ~0x20
            self.sim_pump_at = when + self.sim_cycles_per_byte
        elif d[self.spec.ucsrb] & 0x08:
            d[a] |= 0x20
            if d[self.spec.ucsrb] & 0x20:
                self.sim_pump_at = when + self.sim_cycles_per_byte
        self.avr.irq_dirty = True


class AVR:
    def __init__(self, flash_bytes, variant='atmega328p'):
        v = self.variant = VARIANTS[variant] if isinstance(variant, str) else variant
        self.flash = [0] * v.flash_words
        for i in range(0, min(len(flash_bytes), v.flash_words * 2), 2):
            self.flash[i // 2] = flash_bytes[i] | ((flash_bytes[i + 1] << 8) if i + 1 < len(flash_bytes) else 0)
        self.pc_mask = v.flash_words - 1
        self.data = [0] * v.data_size
        self.eeprom = [0xFF] * v.eeprom_size
        self.pin_count = len(v.pins)
        self.pin_volts = [0.0] * self.pin_count
        self.pin_high = [False] * self.pin_count
        self.vcc = 5.0
        self.timers = [Timer(self, spec) for spec in v.timers]
        self.uarts = [Uart(self, spec) for spec in v.uarts]
        # where each port bit is bonded out: port index -> [pin index or -1] * 8
        self.port_pins = [[-1] * 8 for _ in v.ports]
        for index, (port, bit) in enumerate(v.pins):
            self.port_pins[port][bit] = index
        # interrupt sources by priority: (vector, mask register, bit, flag register, bit, cleared on entry)
        sources = []
        for spec in v.timers:
            for unit, vector in enumerate(spec.comp_vectors):
                sources.append((vector, spec.timsk, spec.comp_bits[unit], spec.tifr, spec.comp_bits[unit], True))
            sources.append((spec.ovf_vector, spec.timsk, spec.ovf_bit, spec.tifr, spec.ovf_bit, True))
            if spec.capt_vector is not None:
                sources.append((spec.capt_vector, spec.timsk, spec.capt_bit, spec.tifr, spec.capt_bit, True))
        for spec in v.uarts:
            sources.append((spec.rx_vector, spec.ucsrb, 0x80, spec.ucsra, 0x80, False))
            sources.append((spec.udre_vector, spec.ucsrb, 0x20, spec.ucsra, 0x20, False))
            sources.append((spec.tx_vector, spec.ucsrb, 0x40, spec.ucsra, 0x40, True))
        sources.append((v.adc['vector'], v.adc['adcsra'], 0x08, v.adc['adcsra'], 0x10, True))
        for (_, _, _, mask, mbit, flag, fbit, vector) in v.ext_ints:
            sources.append((vector, mask, mbit, flag, fbit, True))
        for (control, cbit, flag, fbit, _, _, vector) in v.pcints:
            sources.append((vector, control, cbit, flag, fbit, True))
        self.sources = sorted(sources)
        self.handlers = self.build_handlers()
        # 4 cycles on the chip (5 with a 3-byte PC); simavr (the reference these tests compare with) charges none
        self.interrupt_cycles = 4 if v.pc_bytes == 2 else 5
        # instructions that run after SEI (or a write setting I) before an interrupt: 1 on the chip, 2 in simavr
        self.enable_delay = 1
        # the chip's transmitter takes the next byte while the last one is still going out; simavr's does not
        self.uart_double_buffered = True
        # in PWM modes OCR takes effect at TOP or BOTTOM; simavr uses it at once
        self.pwm_double_buffered = True
        # writing 1 to the ADC's interrupt flag clears it (simavr leaves it)
        self.flags_clear_on_write = True
        self.reset()

    def reset(self):
        v = self.variant
        d = self.data
        for i in range(len(d)): d[i] = 0
        self.pc = 0
        self.cycles = 0
        sp = v.data_size - 1
        d[SPL], d[SPH] = sp & 0xFF, sp >> 8
        for timer in self.timers: timer.reset()
        for uart in self.uarts: uart.reset()
        if not self.uart_double_buffered:
            for uart in self.uarts: d[uart.spec.ucsrb] = 0x08
        self.adc_done_at = None
        self.adc_first = False
        self.interrupt_delay = 0
        self.ext_previous = [False] * len(v.ext_ints)
        self.ext_watch = False
        self.pc_previous = [0] * len(v.pcints)
        self.pc_watch = False
        self.irq_dirty = True
        self.irq_cached = None

    def simavr_mode(self):
        """Behave as simavr does where it differs from the chip, to compare with it instruction by instruction"""
        self.interrupt_cycles = 0
        self.enable_delay = 2
        self.uart_double_buffered = False
        self.flags_clear_on_write = False
        self.pwm_double_buffered = False
        for uart in self.uarts:
            self.data[uart.spec.ucsrb] = 0x08

    @property
    def serial_out(self):
        return self.uarts[0].output if self.uarts else []

    @property
    def serial_in(self):
        return self.uarts[0].input if self.uarts else []

    # ---------------------------------------------------------------- registers with behaviour

    def build_handlers(self):
        """address -> (kind, object, unit)"""
        v = self.variant
        h = {}
        for port, address in enumerate(v.ports):
            h[address] = ('pin', port, 0)
            h[address + 1] = ('levels', port, 0)
            h[address + 2] = ('levels', port, 0)
        for address in v.clear_on_write:
            h[address] = ('clear', None, 0)
        for address in v.mask_registers:
            h[address] = ('mask', None, 0)
        h[SREG] = ('sreg', None, 0)
        for timer in self.timers:
            sp = timer.spec
            if sp.kind == 'std16':
                h[sp.tcnt] = ('tcnt16l', timer, 0)
                h[sp.tcnt + 1] = ('tcnt16h', timer, 0)
                for unit, address in enumerate(sp.ocr):
                    h[address] = ('ocr16l', timer, unit)
                    h[address + 1] = ('ocr16h', timer, unit)
                h[sp.icr] = ('icr16l', timer, 0)
                h[sp.icr + 1] = ('icr16h', timer, 0)
                h[sp.tccrb] = ('clock', timer, 0)
            else:
                h[sp.tcnt] = ('tcnt8', timer, 0)
                for unit, address in enumerate(sp.ocr):
                    h[address] = ('ocr8', timer, unit)
                if sp.kind == 'tiny1':
                    h[sp.tccra] = ('clock', timer, 0)  # TCCR1 holds the clock select
                    h[sp.ocr_top] = ('ocrc', timer, 0)
                else:
                    h[sp.tccrb] = ('clock', timer, 0)
        for uart in self.uarts:
            sp = uart.spec
            h[sp.udr] = ('udr', uart, 0)
            h[sp.ucsra] = ('ucsra', uart, 0)
            h[sp.ucsrb] = ('ucsrb', uart, 0)
            h[sp.ubrrl] = ('ubrrl', uart, 0)
        h[v.adc['adcsra']] = ('adcsra', None, 0)
        for (_, control, _, _, _, _, _, _) in v.ext_ints:
            h[control] = ('extctl', None, 0)
        for (_, _, _, _, mask, _, _) in v.pcints:
            h[mask] = ('pcmsk', None, 0)
        h[v.eeprom_regs[0]] = ('eecr', None, 0)
        return h

    def read(self, address):
        d = self.data
        if address < 0x20 or address >= self.variant.io_end:
            return d[address] if address < len(d) else 0
        handler = self.handlers.get(address)
        if handler is None:
            return d[address]
        kind, obj, unit = handler
        if kind == 'pin':
            return self.pin_register(obj)
        if kind == 'tcnt8':
            return obj.count & 0xFF
        if kind == 'ocr8':
            return obj.ocr_buffer[unit] & 0xFF
        if kind == 'ocrc':
            return obj.top_c
        if kind == 'tcnt16l':
            obj.temp = (obj.count >> 8) & 0xFF
            return obj.count & 0xFF
        if kind == 'icr16l':
            obj.temp = (obj.icr >> 8) & 0xFF
            return obj.icr & 0xFF
        if kind in ('tcnt16h', 'icr16h'):
            return obj.temp
        if kind == 'ocr16l':
            return obj.ocr_buffer[unit] & 0xFF
        if kind == 'ocr16h':
            return (obj.ocr_buffer[unit] >> 8) & 0xFF
        if kind == 'udr':
            return obj.read_data()
        return d[address]

    def pin_register(self, port):
        address = self.variant.ports[port]
        value = 0
        for bit, pin in enumerate(self.port_pins[port]):
            if pin >= 0 and self.pin_high[pin]:
                value |= 1 << bit
        # driven pins read back what they drive
        ddr, out = self.data[address + 1], self.data[address + 2]
        return (value & ~ddr | out & ddr) & 0xFF

    def write(self, address, value):
        value &= 0xFF
        d = self.data
        if address < 0x20 or address >= self.variant.io_end:
            if address < len(d): d[address] = value
            return
        handler = self.handlers.get(address)
        if handler is None:
            d[address] = value
            return
        kind, obj, unit = handler
        if kind == 'pin':
            d[address + 2] ^= value  # writing 1 to PINx toggles PORTx
            self.levels_changed()
        elif kind == 'levels':
            d[address] = value
            self.levels_changed()
        elif kind == 'clear':
            d[address] &= ~value  # writing 1 clears a flag
            self.irq_dirty = True
        elif kind == 'mask':
            d[address] = value
            self.irq_dirty = True
        elif kind == 'sreg':
            if value & I and not d[SREG] & I:
                self.interrupt_delay = self.enable_delay  # as after SEI, one more instruction runs first
            d[SREG] = value
        elif kind == 'tcnt8':
            obj.count = value
        elif kind == 'ocr8':
            obj.write_ocr(unit, value)
        elif kind == 'ocrc':
            obj.top_c = value
        elif kind in ('tcnt16h', 'ocr16h', 'icr16h'):
            obj.temp = value
        elif kind == 'tcnt16l':
            obj.count = obj.temp << 8 | value
        elif kind == 'ocr16l':
            obj.write_ocr(unit, obj.temp << 8 | value)
        elif kind == 'icr16l':
            obj.icr = obj.temp << 8 | value
        elif kind == 'clock':
            mask = 0x0F if obj.spec.kind == 'tiny1' else 7
            if (d[address] ^ value) & mask:
                obj.accumulator = 0  # the prescaler starts over when the clock changes
            d[address] = value
        elif kind == 'udr':
            obj.write_data(value)
        elif kind == 'ucsra':
            obj.write_status(value)
        elif kind == 'ucsrb':
            obj.write_control(value)
        elif kind == 'ubrrl':
            if self.uart_double_buffered: d[address] = value
            else: obj.write_rate_low(value)
        elif kind == 'adcsra':
            self.adc_control_write(value)
        elif kind == 'extctl':
            d[address] = value
            self.ext_watch = False
            for k, (pin, control, shift, *_rest) in enumerate(self.variant.ext_ints):
                self.ext_previous[k] = self.external_level(pin)  # edges are watched from now on
                if (d[control] >> shift) & 3: self.ext_watch = True
        elif kind == 'pcmsk':
            d[address] = value
            self.pc_watch = False
            for k, (_, _, _, _, mask, pins, _) in enumerate(self.variant.pcints):
                self.pc_previous[k] = self.pin_change_levels(pins)
                if d[mask]: self.pc_watch = True
        elif kind == 'eecr':
            self.eeprom_control_write(value)
        else:
            d[address] = value

    def write_bit(self, address, bit, value):
        handler = self.handlers.get(address)
        mask = 1 << bit
        if handler is not None and handler[0] == 'pin':
            if value:
                self.data[address + 2] ^= mask
                self.levels_changed()
            return
        if handler is not None and handler[0] == 'clear':
            if value:
                self.data[address] &= ~mask
                self.irq_dirty = True
            return
        current = self.read(address)
        self.write(address, (current | mask) if value else (current & ~mask))

    # ---------------------------------------------------------------- EEPROM, ADC

    def eeprom_control_write(self, value):
        d = self.data
        eecr, eedr, eearl, eearh = self.variant.eeprom_regs
        d[eecr] = value
        cell = (d[eearh] << 8 | d[eearl]) & (self.variant.eeprom_size - 1)
        if value & 0x01:
            d[eedr] = self.eeprom[cell]
            d[eecr] &= ~0x01
        if value & 0x02:
            self.eeprom[cell] = d[eedr]
            d[eecr] &= ~0x06

    def adc_control_write(self, value):
        d = self.data
        a = self.variant.adc['adcsra']
        old = d[a]
        new = (value & ~0x10) | (old & 0x10)
        if value & 0x10 and self.flags_clear_on_write:
            new &= ~0x10  # writing 1 clears ADIF
        if old & 0x40:
            new |= 0x40  # a conversion in progress cannot be stopped by writing 0 to ADSC
        if not old & 0x80 and new & 0x80:
            self.adc_first = True  # the first conversion after enabling takes 25 ADC clocks, not 13
        if old & 0x80 and not new & 0x80:
            self.adc_done_at = None
            new &= ~0x40
        d[a] = new
        self.irq_dirty = True
        if not old & 0x40 and new & 0x40 and new & 0x80:
            prescale = [2, 2, 4, 8, 16, 32, 64, 128][new & 7]
            self.adc_done_at = self.cycles + (25 if self.adc_first else 13) * prescale

    def adc_finish(self):
        d = self.data
        adc = self.variant.adc
        admux = d[adc['admux']]
        if adc['tiny']:
            mux = admux & 0x0F
            refs = (admux >> 6) & 3 | ((admux >> 4) & 1) << 2
        else:
            mux = admux & adc['mux_mask']
            if adc['mux5'] and d[adc['adcsrb']] & 0x08: mux |= 0x20
            refs = (admux >> 6) & 3
        source = self.variant.adc_channels.get(mux, ADC_GROUND)
        volts = 0.0 if source == ADC_GROUND else 1.1 if source == ADC_BANDGAP else self.pin_volts[source]
        reference = self.variant.adc_references.get(refs)
        reference = self.vcc if reference is None else reference
        value = max(0, min(1023, int(volts / max(reference, 0.1) * 1024)))
        if admux & 0x20:  # left adjusted
            value <<= 6
        d[adc['adcl']], d[adc['adch']] = value & 0xFF, (value >> 8) & 0xFF
        d[adc['adcsra']] = (d[adc['adcsra']] & ~0x40) | 0x10
        self.adc_done_at = None
        self.adc_first = False
        self.irq_dirty = True

    # ---------------------------------------------------------------- interrupts

    def levels_changed(self):
        """Pin levels may have changed (an input voltage, PORT or DDR): look for edges"""
        if self.ext_watch: self.external_interrupts()
        if self.pc_watch: self.pin_change_interrupts()

    def external_level(self, pin):
        """What an interrupt pin sees: the circuit's level, or what the pin drives"""
        port, bit = self.variant.pins[pin]
        address = self.variant.ports[port]
        if (self.data[address + 1] >> bit) & 1:
            return bool((self.data[address + 2] >> bit) & 1)
        return self.pin_high[pin]

    def external_interrupts(self):
        d = self.data
        for k, (pin, control, shift, _, _, flag, fbit, _) in enumerate(self.variant.ext_ints):
            level = self.external_level(pin)
            sense = (d[control] >> shift) & 3
            previous = self.ext_previous[k]
            if (sense == 1 and level != previous) or (sense == 2 and previous and not level) or (sense == 3 and level and not previous):
                d[flag] |= fbit
                self.irq_dirty = True
            self.ext_previous[k] = level

    def pin_change_levels(self, pins):
        value = 0
        for bit, pin in enumerate(pins):
            if pin >= 0 and self.external_level(pin): value |= 1 << bit
        return value

    def pin_change_interrupts(self):
        d = self.data
        for k, (_, _, flag, fbit, mask, pins, _) in enumerate(self.variant.pcints):
            levels = self.pin_change_levels(pins)
            if (levels ^ self.pc_previous[k]) & d[mask]:
                d[flag] |= fbit
                self.irq_dirty = True
            self.pc_previous[k] = levels

    def pending_interrupt(self):
        """The highest-priority interrupt that is enabled and flagged, as its source tuple (or None)"""
        if self.irq_dirty:
            d = self.data
            self.irq_cached = None
            for source in self.sources:
                if d[source[1]] & source[2] and d[source[3]] & source[4]:
                    self.irq_cached = source
                    break
            self.irq_dirty = False
        return self.irq_cached

    def interrupt_ready(self):
        return self.interrupt_delay == 0 and self.data[SREG] & I and self.pending_interrupt() is not None

    # ---------------------------------------------------------------- pins seen from outside

    def set_pin_volts(self, volts):
        self.pin_volts = list(volts)
        for i, v in enumerate(self.pin_volts):
            # CMOS input: high above 0.6 of the supply, low below 0.3, otherwise as it was
            if v > 0.6 * self.vcc: self.pin_high[i] = True
            elif v < 0.3 * self.vcc: self.pin_high[i] = False
        self.levels_changed()

    def pin_states(self):
        """For each pin: ('out', high) or ('in', pull_up); timer outputs and the USART override PORT"""
        d = self.data
        v = self.variant
        overrides = {}
        for timer in self.timers:
            for unit in range(timer.units):
                com = timer.compare_output(unit)
                if com and timer.spec.pins[unit] >= 0:
                    overrides[timer.spec.pins[unit]] = timer.output[unit]
                    if timer.spec.kind == 'tiny1' and com == 1 and timer.pwm_unit(unit):
                        overrides[timer.spec.complements[unit]] = not timer.output[unit]
        result = []
        for index, (port, bit) in enumerate(v.pins):
            address = v.ports[port]
            if (d[address + 1] >> bit) & 1:
                result.append(('out', overrides.get(index, bool((d[address + 2] >> bit) & 1))))
            else:
                result.append(('in', bool((d[address + 2] >> bit) & 1)))
        for uart in self.uarts:
            control = d[uart.spec.ucsrb]
            if control & 0x08: result[uart.spec.tx_pin] = ('out', True)  # the transmitter idles high
            if control & 0x10:
                port, bit = v.pins[uart.spec.rx_pin]
                result[uart.spec.rx_pin] = ('in', bool((d[v.ports[port] + 2] >> bit) & 1))
        return result

    # ---------------------------------------------------------------- running

    def tick(self, cycles):
        self.cycles += cycles
        for timer in self.timers:
            timer.advance(cycles)
        for uart in self.uarts:
            if uart.needs_update(): uart.update()
        if self.adc_done_at is not None and self.cycles >= self.adc_done_at:
            self.adc_finish()

    def step(self):
        """Runs one instruction (or takes an interrupt); returns cycles used"""
        if self.interrupt_delay == 0 and self.data[SREG] & I:
            source = self.pending_interrupt()
            if source is not None:
                vector, _, _, flag, fbit, clears = source
                if clears:
                    self.data[flag] &= ~fbit
                self.irq_dirty = True
                self.push_pc(self.pc)
                self.data[SREG] &= ~I
                self.pc = vector * self.variant.vector_words
                self.tick(self.interrupt_cycles)
                return self.interrupt_cycles
        if self.interrupt_delay:
            self.interrupt_delay -= 1
        cycles = self.execute()
        self.tick(cycles)
        return cycles

    def run(self, cycles):
        end = self.cycles + cycles
        while self.cycles < end:
            self.step()

    # ---------------------------------------------------------------- CPU helpers

    def push(self, value):
        sp = self.data[SPL] | self.data[SPH] << 8
        if sp < len(self.data): self.data[sp] = value & 0xFF
        sp = (sp - 1) & 0xFFFF
        self.data[SPL], self.data[SPH] = sp & 0xFF, sp >> 8

    def pop(self):
        sp = ((self.data[SPL] | self.data[SPH] << 8) + 1) & 0xFFFF
        self.data[SPL], self.data[SPH] = sp & 0xFF, sp >> 8
        return self.data[sp] if sp < len(self.data) else 0

    def push_pc(self, pc):
        self.push(pc & 0xFF)
        self.push((pc >> 8) & 0xFF)
        if self.variant.pc_bytes == 3: self.push((pc >> 16) & 0xFF)

    def pop_pc(self):
        value = 0
        for _ in range(self.variant.pc_bytes):
            value = value << 8 | self.pop()
        return value & self.pc_mask

    def set_flags(self, mask, values):
        self.data[SREG] = (self.data[SREG] & ~mask | values) & 0xFF

    def flags_add(self, a, b, result):
        r = result & 0xFF
        carries = (a & b) | (b & ~r) | (~r & a)
        v = ((a & b & ~r) | (~a & ~b & r)) & 0x80
        n = r & 0x80
        f = (C if carries & 0x80 else 0) | (Z if r == 0 else 0) | (N if n else 0) | (V if v else 0) | (H if carries & 0x08 else 0)
        f |= S if bool(n) != bool(v) else 0
        self.set_flags(C | Z | N | V | S | H, f)
        return r

    def flags_sub(self, a, b, result, keep_z=False):
        r = result & 0xFF
        borrows = (~a & b) | (b & r) | (r & ~a)
        v = ((a & ~b & ~r) | (~a & b & r)) & 0x80
        n = r & 0x80
        f = (C if borrows & 0x80 else 0) | (N if n else 0) | (V if v else 0) | (H if borrows & 0x08 else 0)
        f |= S if bool(n) != bool(v) else 0
        if r == 0 and (not keep_z or self.data[SREG] & Z):
            f |= Z
        self.set_flags(C | Z | N | V | S | H, f)
        return r

    def flags_logic(self, r):
        r &= 0xFF
        n = r & 0x80
        self.set_flags(Z | N | V | S, (Z if r == 0 else 0) | (N | S if n else 0))
        return r

    def shift_flags(self, rd, a, r):
        r &= 0xFF
        c = a & 1
        n = bool(r & 0x80)
        v = n != bool(c)
        self.set_flags(C | Z | N | V | S, (C if c else 0) | (Z if r == 0 else 0) | (N if n else 0) | (V if v else 0) | (S if n != v else 0))
        self.data[rd] = r
        return 1

    def multiply_result(self, product, fractional):
        d = self.data
        c = (product >> 15) & 1
        if fractional:
            product <<= 1
        product &= 0xFFFF
        d[0], d[1] = product & 0xFF, product >> 8
        self.set_flags(C | Z, (C if c else 0) | (Z if product == 0 else 0))
        return 2

    @staticmethod
    def instruction_words(op):
        # 32-bit instructions: LDS, STS, JMP, CALL
        return 2 if (op & 0xFE0F) in (0x9000, 0x9200) or (op & 0xFE0E) in (0x940C, 0x940E) else 1

    def skip(self):
        words = self.instruction_words(self.flash[self.pc])
        self.pc = (self.pc + words) & self.pc_mask
        return 1 + words

    def program_byte(self, z):
        word = self.flash[(z >> 1) & self.pc_mask]
        return (word >> 8) if z & 1 else (word & 0xFF)

    def extended(self):
        """RAMPZ:Z for ELPM (Z alone on chips without RAMPZ)"""
        z = self.data[30] | self.data[31] << 8
        return z | (self.data[RAMPZ] << 16) if self.variant.pc_bytes == 3 else z

    # ---------------------------------------------------------------- one instruction

    def execute(self):
        d = self.data
        mask = self.pc_mask
        op = self.flash[self.pc]
        pc = self.pc
        self.pc = (pc + 1) & mask
        rd5 = (op >> 4) & 0x1F
        rr5 = (op & 0x0F) | ((op >> 5) & 0x10)
        rd4 = 16 + ((op >> 4) & 0x0F)
        k8 = (op & 0x0F) | ((op >> 4) & 0xF0)
        hi4 = op >> 12
        three = self.variant.pc_bytes == 3

        if op == 0x0000:
            return 1  # NOP
        if hi4 == 0x0:
            top = op & 0xFC00
            if top == 0x0C00:  # ADD
                a, b = d[rd5], d[rr5]
                d[rd5] = self.flags_add(a, b, a + b)
                return 1
            if top == 0x0800:  # SBC
                a, b, c = d[rd5], d[rr5], d[SREG] & C
                d[rd5] = self.flags_sub(a, b, a - b - c, keep_z=True)
                return 1
            if top == 0x0400:  # CPC
                a, b, c = d[rd5], d[rr5], d[SREG] & C
                self.flags_sub(a, b, a - b - c, keep_z=True)
                return 1
            if (op & 0xFF00) == 0x0100:  # MOVW
                dd, rr = ((op >> 4) & 0x0F) * 2, (op & 0x0F) * 2
                d[dd], d[dd + 1] = d[rr], d[rr + 1]
                return 1
            if (op & 0xFF00) == 0x0200:  # MULS
                a, b = d[16 + ((op >> 4) & 0x0F)], d[16 + (op & 0x0F)]
                a = a - 256 if a & 0x80 else a
                b = b - 256 if b & 0x80 else b
                return self.multiply_result(a * b, False)
            a, b = d[16 + ((op >> 4) & 7)], d[16 + (op & 7)]
            sa = a - 256 if a & 0x80 else a
            sb = b - 256 if b & 0x80 else b
            low = op & 0xFF88
            if low == 0x0300: return self.multiply_result(sa * b, False)   # MULSU
            if low == 0x0308: return self.multiply_result(a * b, True)     # FMUL
            if low == 0x0380: return self.multiply_result(sa * sb, True)   # FMULS
            if low == 0x0388: return self.multiply_result(sa * b, True)    # FMULSU
            return 1
        if hi4 == 0x1:
            top = op & 0xFC00
            a, b = d[rd5], d[rr5]
            if top == 0x1C00:  # ADC
                c = d[SREG] & C
                d[rd5] = self.flags_add(a, b, a + b + c)
            elif top == 0x1800:  # SUB
                d[rd5] = self.flags_sub(a, b, a - b)
            elif top == 0x1400:  # CP
                self.flags_sub(a, b, a - b)
            elif a == b:  # CPSE
                return self.skip()
            return 1
        if hi4 == 0x2:
            top = op & 0xFC00
            if top == 0x2000: d[rd5] = self.flags_logic(d[rd5] & d[rr5])    # AND
            elif top == 0x2400: d[rd5] = self.flags_logic(d[rd5] ^ d[rr5])  # EOR
            elif top == 0x2800: d[rd5] = self.flags_logic(d[rd5] | d[rr5])  # OR
            else: d[rd5] = d[rr5]  # MOV
            return 1
        if hi4 == 0x3:  # CPI
            a = d[rd4]
            self.flags_sub(a, k8, a - k8)
            return 1
        if hi4 == 0x4:  # SBCI
            a, c = d[rd4], d[SREG] & C
            d[rd4] = self.flags_sub(a, k8, a - k8 - c, keep_z=True)
            return 1
        if hi4 == 0x5:  # SUBI
            a = d[rd4]
            d[rd4] = self.flags_sub(a, k8, a - k8)
            return 1
        if hi4 == 0x6:  # ORI
            d[rd4] = self.flags_logic(d[rd4] | k8)
            return 1
        if hi4 == 0x7:  # ANDI
            d[rd4] = self.flags_logic(d[rd4] & k8)
            return 1
        if hi4 in (0x8, 0xA):  # LDD / STD with displacement from Y or Z (LD / ST Y and Z too)
            q = (op & 0x07) | ((op >> 7) & 0x18) | ((op >> 8) & 0x20)
            base = 28 if op & 0x08 else 30
            address = (d[base] | d[base + 1] << 8) + q
            if op & 0x0200: self.write(address, d[rd5])
            else: d[rd5] = self.read(address)
            return 2
        if hi4 == 0x9:
            return self.execute_9(op, rd5, rr5)
        if hi4 == 0xB:  # IN / OUT
            address = (((op >> 5) & 0x30) | (op & 0x0F)) + 0x20
            if op & 0x0800: self.write(address, d[rd5])
            else: d[rd5] = self.read(address)
            return 1
        if hi4 == 0xC:  # RJMP
            k = op & 0x0FFF
            if k & 0x800: k -= 0x1000
            self.pc = (self.pc + k) & mask
            return 2
        if hi4 == 0xD:  # RCALL
            k = op & 0x0FFF
            if k & 0x800: k -= 0x1000
            self.push_pc(self.pc)
            self.pc = (self.pc + k) & mask
            return 4 if three else 3
        if hi4 == 0xE:  # LDI
            d[rd4] = k8
            return 1
        # 0xF
        if (op & 0xF800) in (0xF000, 0xF400):  # BRBS / BRBC
            bit = 1 << (op & 7)
            k = (op >> 3) & 0x7F
            if k & 0x40: k -= 0x80
            if bool(d[SREG] & bit) == ((op & 0x0400) == 0):
                self.pc = (self.pc + k) & mask
                return 2
            return 1
        bit = op & 7
        kind = op & 0xFE08
        if kind == 0xF800:  # BLD
            if d[SREG] & T: d[rd5] |= 1 << bit
            else: d[rd5] &= ~(1 << bit) & 0xFF
            return 1
        if kind == 0xFA00:  # BST
            self.set_flags(T, T if (d[rd5] >> bit) & 1 else 0)
            return 1
        if kind == 0xFC00:  # SBRC
            return self.skip() if not (d[rd5] >> bit) & 1 else 1
        if kind == 0xFE00:  # SBRS
            return self.skip() if (d[rd5] >> bit) & 1 else 1
        return 1

    def execute_9(self, op, rd5, rr5):
        d = self.data
        mask = self.pc_mask
        three = self.variant.pc_bytes == 3
        if (op & 0xFC00) == 0x9C00:  # MUL
            return self.multiply_result(d[rd5] * d[rr5], False)
        if (op & 0xFE00) in (0x9000, 0x9200):
            store = op & 0x0200
            mode = op & 0x0F
            if mode == 0x0:  # LDS / STS
                address = self.flash[self.pc]
                self.pc = (self.pc + 1) & mask
                if store: self.write(address, d[rd5])
                else: d[rd5] = self.read(address)
                return 2
            if mode in (0x4, 0x5, 0x6, 0x7):
                if store: return 1  # XCH, LAS, LAC, LAT are not on these chips
                if mode in (0x4, 0x5):  # LPM Rd, Z(+)
                    z = d[30] | d[31] << 8
                    d[rd5] = self.program_byte(z)
                    if mode == 0x5:
                        z = (z + 1) & 0xFFFF
                        d[30], d[31] = z & 0xFF, z >> 8
                    return 3
                z = self.extended()  # ELPM Rd, Z(+)
                d[rd5] = self.program_byte(z)
                if mode == 0x7:
                    z += 1
                    d[30], d[31] = z & 0xFF, (z >> 8) & 0xFF
                    if three: d[RAMPZ] = (z >> 16) & 0xFF
                return 3
            if mode == 0xF:  # PUSH / POP
                if store: self.push(d[rd5])
                else: d[rd5] = self.pop()
                return 2
            pointers = {0x1: (30, 1), 0x2: (30, -1), 0x9: (28, 1), 0xA: (28, -1), 0xC: (26, 0), 0xD: (26, 1), 0xE: (26, -1)}
            if mode in pointers:
                base, change = pointers[mode]
                p = d[base] | d[base + 1] << 8
                if change < 0: p = (p - 1) & 0xFFFF
                if store: self.write(p, d[rd5])
                else: d[rd5] = self.read(p)
                if change > 0: p = (p + 1) & 0xFFFF
                d[base], d[base + 1] = p & 0xFF, p >> 8
                return 2
            return 1
        if (op & 0xFE00) == 0x9400:
            low = op & 0x0F
            if low == 0x0:  # COM
                r = (~d[rd5]) & 0xFF
                n = r & 0x80
                self.set_flags(C | Z | N | V | S, C | (Z if r == 0 else 0) | (N | S if n else 0))
                d[rd5] = r
                return 1
            if low == 0x1:  # NEG
                a = d[rd5]
                r = (-a) & 0xFF
                v = r == 0x80
                n = r & 0x80
                f = (C if r != 0 else Z) | (N if n else 0) | (V if v else 0) | (H if (r | a) & 0x08 else 0)
                f |= S if bool(n) != v else 0
                self.set_flags(C | Z | N | V | S | H, f)
                d[rd5] = r
                return 1
            if low == 0x2:  # SWAP
                a = d[rd5]
                d[rd5] = ((a << 4) | (a >> 4)) & 0xFF
                return 1
            if low == 0x3:  # INC
                r = (d[rd5] + 1) & 0xFF
                v = r == 0x80
                n = r & 0x80
                self.set_flags(Z | N | V | S, (Z if r == 0 else 0) | (N if n else 0) | (V if v else 0) | (S if bool(n) != v else 0))
                d[rd5] = r
                return 1
            if low == 0x5:  # ASR
                a = d[rd5]
                return self.shift_flags(rd5, a, (a >> 1) | (a & 0x80))
            if low == 0x6:  # LSR
                a = d[rd5]
                return self.shift_flags(rd5, a, a >> 1)
            if low == 0x7:  # ROR
                a = d[rd5]
                return self.shift_flags(rd5, a, (a >> 1) | (0x80 if d[SREG] & C else 0))
            if low == 0xA:  # DEC
                r = (d[rd5] - 1) & 0xFF
                v = r == 0x7F
                n = r & 0x80
                self.set_flags(Z | N | V | S, (Z if r == 0 else 0) | (N if n else 0) | (V if v else 0) | (S if bool(n) != v else 0))
                d[rd5] = r
                return 1
            if low in (0xC, 0xD):  # JMP
                k = self.flash[self.pc] | ((op & 0x01F0) << 13) | ((op & 1) << 16)
                self.pc = k & mask
                return 3
            if low in (0xE, 0xF):  # CALL
                k = self.flash[self.pc] | ((op & 0x01F0) << 13) | ((op & 1) << 16)
                self.push_pc((self.pc + 1) & mask)
                self.pc = k & mask
                return 5 if three else 4
            if (op & 0xFF8F) == 0x9408:  # BSET (SEI, SEC…)
                b = (op >> 4) & 7
                d[SREG] |= 1 << b
                if b == 7: self.interrupt_delay = self.enable_delay
                return 1
            if (op & 0xFF8F) == 0x9488:  # BCLR
                d[SREG] &= ~(1 << ((op >> 4) & 7)) & 0xFF
                return 1
            if op == 0x9508:  # RET
                self.pc = self.pop_pc()
                return 5 if three else 4
            if op == 0x9518:  # RETI
                self.pc = self.pop_pc()
                d[SREG] |= I
                self.interrupt_delay = self.enable_delay
                return 5 if three else 4
            if op == 0x95C8:  # LPM (R0)
                d[0] = self.program_byte(d[30] | d[31] << 8)
                return 3
            if op == 0x95D8:  # ELPM (R0)
                d[0] = self.program_byte(self.extended())
                return 3
            if op == 0x9409:  # IJMP
                self.pc = (d[30] | d[31] << 8) & mask
                return 2
            if op == 0x9419:  # EIJMP
                self.pc = ((d[30] | d[31] << 8) | (d[EIND] << 16 if three else 0)) & mask
                return 2
            if op == 0x9509:  # ICALL
                self.push_pc(self.pc)
                self.pc = (d[30] | d[31] << 8) & mask
                return 4 if three else 3
            if op == 0x9519:  # EICALL
                self.push_pc(self.pc)
                self.pc = ((d[30] | d[31] << 8) | (d[EIND] << 16 if three else 0)) & mask
                return 4 if three else 3
            return 1  # SLEEP, WDR, BREAK, SPM
        if (op & 0xFE00) == 0x9600:  # ADIW / SBIW
            dd = 24 + ((op >> 3) & 0x06)
            k = (op & 0x0F) | ((op >> 2) & 0x30)
            a = d[dd] | d[dd + 1] << 8
            if not op & 0x0100:
                r = (a + k) & 0xFFFF
                v = bool(~a & r & 0x8000)
                c = bool(~r & a & 0x8000)
            else:
                r = (a - k) & 0xFFFF
                v = bool(a & ~r & 0x8000)
                c = bool(r & ~a & 0x8000)
            n = bool(r & 0x8000)
            self.set_flags(C | Z | N | V | S, (C if c else 0) | (Z if r == 0 else 0) | (N if n else 0) | (V if v else 0) | (S if n != v else 0))
            d[dd], d[dd + 1] = r & 0xFF, r >> 8
            return 2
        if (op & 0xFC00) == 0x9800:  # CBI, SBIC, SBI, SBIS
            address = 0x20 + ((op >> 3) & 0x1F)
            bit = op & 7
            kind = op & 0x0300
            if kind == 0x0000:
                self.write_bit(address, bit, False)
                return 2
            if kind == 0x0200:
                self.write_bit(address, bit, True)
                return 2
            value = (self.read(address) >> bit) & 1
            if (kind == 0x0100 and not value) or (kind == 0x0300 and value):
                return self.skip()
            return 1
        return 1


def load(path, variant='atmega328p'):
    return AVR(open(path, 'rb').read(), variant)
