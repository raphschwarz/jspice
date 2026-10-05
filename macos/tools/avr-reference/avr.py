"""Reference ATmega328P emulator, written to be ported line by line to Swift (CircuitKit/AVR.swift).

Data space: r0-r31 at 0x00-0x1F, I/O at 0x20-0x5F (IN/OUT address + 0x20), extended I/O 0x60-0xFF, SRAM 0x100-0x8FF.
"""

# I/O addresses in data space
PINB, DDRB, PORTB, PINC, DDRC, PORTC, PIND, DDRD, PORTD = 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B
TIFR0, TIFR1, TIFR2, PCIFR, EIFR, EIMSK = 0x35, 0x36, 0x37, 0x3B, 0x3C, 0x3D
EECR, EEDR, EEARL, EEARH = 0x3F, 0x40, 0x41, 0x42
TCCR0A, TCCR0B, TCNT0, OCR0A, OCR0B = 0x44, 0x45, 0x46, 0x47, 0x48
SPL, SPH, SREG = 0x5D, 0x5E, 0x5F
EICRA, PCICR, PCMSK0, PCMSK1, PCMSK2 = 0x69, 0x68, 0x6B, 0x6C, 0x6D
TIMSK0, TIMSK1, TIMSK2 = 0x6E, 0x6F, 0x70
ADCL, ADCH, ADCSRA, ADCSRB, ADMUX = 0x78, 0x79, 0x7A, 0x7B, 0x7C
TCCR1A, TCCR1B, TCCR1C, TCNT1L, TCNT1H, ICR1L, ICR1H, OCR1AL, OCR1AH, OCR1BL, OCR1BH = 0x80, 0x81, 0x82, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B
TCCR2A, TCCR2B, TCNT2, OCR2A, OCR2B = 0xB0, 0xB1, 0xB2, 0xB3, 0xB4
UCSR0A, UCSR0B, UCSR0C, UBRR0L, UBRR0H, UDR0 = 0xC0, 0xC1, 0xC2, 0xC4, 0xC5, 0xC6

# interrupt vectors
INT0_V, INT1_V = 1, 2
TIMER2_COMPA_V, TIMER2_COMPB_V, TIMER2_OVF_V = 7, 8, 9
TIMER1_COMPA_V, TIMER1_COMPB_V, TIMER1_OVF_V = 11, 12, 13
TIMER0_COMPA_V, TIMER0_COMPB_V, TIMER0_OVF_V = 14, 15, 16
USART_RX_V, USART_UDRE_V, USART_TX_V, ADC_V = 18, 19, 20, 21

C, Z, N, V, S, H, T, I = 1, 2, 4, 8, 16, 32, 64, 128

# Arduino Uno pins: D0-D7 = PD0-7, D8-D13 = PB0-5, A0-A5 = PC0-5 (pin index 0-19)
PIN_PORTS = [(PIND, d) for d in range(8)] + [(PINB, b) for b in range(6)] + [(PINC, c) for c in range(6)]


class Timer:
    """An 8- or 16-bit timer/counter with two compare units"""

    def __init__(self, avr, index, bits, tccra, tccrb, tcnt, ocra, ocrb, timsk, tifr, vectors, prescalers, pins):
        self.avr, self.index, self.bits = avr, index, bits
        self.tccra, self.tccrb, self.tcnt, self.ocra, self.ocrb = tccra, tccrb, tcnt, ocra, ocrb
        self.timsk, self.tifr = timsk, tifr
        self.vcompa, self.vcompb, self.vovf = vectors
        self.prescalers = prescalers
        self.pins = pins  # pin indices of OCxA, OCxB
        self.count = 0
        self.down = False
        self.accumulator = 0
        self.ocr = [0, 0]          # in use
        self.ocr_buffer = [0, 0]   # written, copied at TOP or BOTTOM in PWM modes
        self.icr = 0
        self.output = [False, False]  # OCxA, OCxB pin states

    def mode(self):
        d = self.avr.data
        wgm = (d[self.tccra] & 3) | ((d[self.tccrb] >> 1) & (0xC if self.bits == 16 else 0x4))
        return wgm

    def top_and_kind(self):
        """(top, kind) where kind is 'normal', 'ctc', 'fast', 'phase'; top_from: 'fixed', 'ocra', 'icr'"""
        w = self.mode()
        if self.bits == 8:
            table = {0: (0xFF, 'normal', 'fixed'), 1: (0xFF, 'phase', 'fixed'), 2: (None, 'ctc', 'ocra'), 3: (0xFF, 'fast', 'fixed'),
                     5: (None, 'phase', 'ocra'), 7: (None, 'fast', 'ocra')}
            top, kind, source = table.get(w, (0xFF, 'normal', 'fixed'))
        else:
            table = {0: (0xFFFF, 'normal', 'fixed'), 1: (0xFF, 'phase', 'fixed'), 2: (0x1FF, 'phase', 'fixed'), 3: (0x3FF, 'phase', 'fixed'),
                     4: (None, 'ctc', 'ocra'), 5: (0xFF, 'fast', 'fixed'), 6: (0x1FF, 'fast', 'fixed'), 7: (0x3FF, 'fast', 'fixed'),
                     8: (None, 'phase', 'icr'), 9: (None, 'phase', 'ocra'), 10: (None, 'phase', 'icr'), 11: (None, 'phase', 'ocra'),
                     12: (None, 'ctc', 'icr'), 14: (None, 'fast', 'icr'), 15: (None, 'fast', 'ocra')}
            top, kind, source = table.get(w, (0xFFFF, 'normal', 'fixed'))
        if source == 'ocra':
            top = self.ocr[0]
        elif source == 'icr':
            top = self.icr
        return top, kind, source

    def prescale(self):
        return self.prescalers[self.avr.data[self.tccrb] & 7]

    def write_ocr(self, unit, value):
        self.ocr_buffer[unit] = value
        _, kind, _ = self.top_and_kind()
        if kind in ('normal', 'ctc'):
            self.ocr[unit] = value

    def flag(self, bit):
        self.avr.data[self.tifr] |= bit

    def compare_output(self, unit, kind):
        """What a compare match does to the pin: COMx1:COMx0 in TCCRxA bits 7:6 (A) and 5:4 (B)"""
        return (self.avr.data[self.tccra] >> (6 - 2 * unit)) & 3

    def match(self, unit, kind):
        com = self.compare_output(unit, kind)
        if com == 0:
            return
        if kind in ('normal', 'ctc'):
            if com == 1: self.output[unit] = not self.output[unit]
            elif com == 2: self.output[unit] = False
            else: self.output[unit] = True
        elif kind == 'fast':
            if com == 2: self.output[unit] = False
            elif com == 3: self.output[unit] = True
            elif com == 1 and unit == 0 and self.top_and_kind()[2] == 'ocra': self.output[0] = not self.output[0]
        else:  # phase correct: clear up-counting, set down-counting (non-inverting)
            if com == 2: self.output[unit] = self.down
            elif com == 3: self.output[unit] = not self.down
            elif com == 1 and unit == 0 and self.top_and_kind()[2] == 'ocra': self.output[0] = not self.output[0]

    def bottom(self, kind):
        """Fast PWM: outputs set (non-inverting) or cleared (inverting) at BOTTOM"""
        if kind == 'fast':
            for unit in (0, 1):
                com = self.compare_output(unit, kind)
                if com == 2: self.output[unit] = True
                elif com == 3: self.output[unit] = False

    def tick(self):
        top, kind, source = self.top_and_kind()
        if kind == 'phase':
            if not self.down:
                self.count += 1
                if self.count >= top:
                    self.count = top
                    self.down = True
                    # double-buffered compare values update at TOP
                    self.ocr = list(self.ocr_buffer)
                    if source == 'ocra': top = self.ocr[0]
            else:
                self.count -= 1
                if self.count <= 0:
                    self.count = 0
                    self.down = False
                    self.flag(1)  # TOV at BOTTOM
            for unit in (0, 1):
                if self.count == self.ocr[unit]:
                    self.flag(2 << unit)
                    self.match(unit, kind)
            return
        old = self.count
        wrapped = False
        if self.count == top and kind in ('ctc', 'fast'):
            self.count = 0
            wrapped = True
            if kind == 'fast':
                self.flag(1)
        elif self.count == (0xFF if self.bits == 8 else 0xFFFF):
            self.count = 0
            wrapped = True
            self.flag(1)
        else:
            self.count += 1
        if kind == 'fast':
            # the pin changes a timer clock after the counter equals OCR (duty (OCR + 1) / (TOP + 1)), and the
            # change at BOTTOM comes after it: OCR = TOP stays high, OCR = 0 gives a one-clock spike
            for unit in (0, 1):
                if old == self.ocr[unit]:
                    self.match(unit, kind)
            if wrapped:
                self.ocr = list(self.ocr_buffer)
                self.bottom(kind)
            for unit in (0, 1):
                if self.count == self.ocr[unit]:
                    self.flag(2 << unit)
            return
        if wrapped and kind == 'normal':
            pass
        for unit in (0, 1):
            if self.count == self.ocr[unit]:
                self.flag(2 << unit)
                self.match(unit, kind)

    def advance(self, cycles):
        prescale = self.prescale()
        if prescale == 0:
            return
        self.accumulator += cycles
        while self.accumulator >= prescale:
            self.accumulator -= prescale
            self.tick()


class AVR:
    def __init__(self, flash_bytes):
        self.flash = [0] * 16384
        for i in range(0, min(len(flash_bytes), 32768) - 1, 2):
            self.flash[i // 2] = flash_bytes[i] | (flash_bytes[i + 1] << 8)
        if len(flash_bytes) % 2:
            self.flash[len(flash_bytes) // 2] = flash_bytes[-1]
        self.data = [0] * 0x900
        self.eeprom = [0xFF] * 1024
        self.pc = 0
        self.cycles = 0
        self.data[SPL], self.data[SPH] = 0xFF, 0x08
        self.data[UCSR0A] = 0x20  # the transmit buffer starts empty
        self.data[UCSR0C] = 0x06
        self.pin_volts = [0.0] * 20
        self.pin_high = [False] * 20
        self.vcc = 5.0
        self.serial_out = []
        self.serial_in = []
        self.uart_tx_busy_until = 0
        self.uart_tx_pending = None
        self.uart_rx_next = 0
        self.adc_done_at = None
        self.adc_first = False
        self.interrupt_delay = 0  # an instruction always runs after RETI or SEI before the next interrupt
        self.timers = [
            Timer(self, 0, 8, TCCR0A, TCCR0B, TCNT0, OCR0A, OCR0B, TIMSK0, TIFR0, (TIMER0_COMPA_V, TIMER0_COMPB_V, TIMER0_OVF_V),
                  [0, 1, 8, 64, 256, 1024, 0, 0], (6, 5)),
            Timer(self, 1, 16, TCCR1A, TCCR1B, TCNT1L, OCR1AL, OCR1BL, TIMSK1, TIFR1, (TIMER1_COMPA_V, TIMER1_COMPB_V, TIMER1_OVF_V),
                  [0, 1, 8, 64, 256, 1024, 0, 0], (9, 10)),
            Timer(self, 2, 8, TCCR2A, TCCR2B, TCNT2, OCR2A, OCR2B, TIMSK2, TIFR2, (TIMER2_COMPA_V, TIMER2_COMPB_V, TIMER2_OVF_V),
                  [0, 1, 8, 32, 64, 128, 256, 1024], (11, 3)),
        ]
        self.temp16 = 0  # the 16-bit timer's shared high-byte register
        self.int_previous = [False, False]
        # 4 on the chip; simavr (the reference these tests compare with) takes interrupts without charging cycles
        self.interrupt_cycles = 4
        # instructions that run after SEI (or a write setting I) before an interrupt: 1 on the chip, 2 in simavr
        self.enable_delay = 1
        # the chip's transmitter takes the next byte while the last one is still going out; simavr's does not
        self.uart_double_buffered = True
        self.sim_tx_count = 0
        self.sim_pump_at = None
        self.sim_cycles_per_byte = 1600
        # writing 1 to the ADC's interrupt flag clears it (simavr leaves it)
        self.flags_clear_on_write = True

    def simavr_mode(self):
        """Behave as simavr does where it differs from the chip, to compare with it instruction by instruction"""
        self.interrupt_cycles = 0
        self.enable_delay = 2
        self.uart_double_buffered = False
        self.data[UCSR0B] = 0x08
        self.flags_clear_on_write = False

    def interrupt_ready(self):
        return self.interrupt_delay == 0 and self.data[SREG] & I and self.pending_interrupt()[0] is not None

    # ---------------------------------------------------------------- data space

    def read(self, address):
        d = self.data
        if address < 0x20 or address >= 0x100:
            return d[address] if address < 0x900 else 0
        if address in (PINB, PINC, PIND):
            return self.pin_register(address)
        if address == TCNT0: return self.timers[0].count & 0xFF
        if address == TCNT2: return self.timers[2].count & 0xFF
        if address == TCNT1L:
            c = self.timers[1].count
            self.temp16 = c >> 8
            return c & 0xFF
        if address == TCNT1H: return self.temp16
        if address == OCR0A: return self.timers[0].ocr_buffer[0]
        if address == OCR0B: return self.timers[0].ocr_buffer[1]
        if address == OCR2A: return self.timers[2].ocr_buffer[0]
        if address == OCR2B: return self.timers[2].ocr_buffer[1]
        if address == UDR0:
            value = d[UDR0]
            d[UCSR0A] &= ~0x80
            return value
        if address == ADCL:
            return d[ADCL]
        return d[address]

    def pin_register(self, address):
        port = {PINB: 8, PINC: 14, PIND: 0}[address]
        count = {PINB: 6, PINC: 6, PIND: 8}[address]
        value = 0
        for bit in range(count):
            if self.pin_high[port + bit]:
                value |= 1 << bit
        # driven pins read back what they drive
        ddr, out = self.data[address + 1], self.data[address + 2]
        return (value & ~ddr | out & ddr) & 0xFF

    def write(self, address, value):
        value &= 0xFF
        d = self.data
        if address < 0x20 or address >= 0x100:
            if address < 0x900: d[address] = value
            return
        if address in (PINB, PINC, PIND):
            d[address + 2] ^= value  # writing 1 to PINx toggles PORTx
            return
        if address in (TIFR0, TIFR1, TIFR2, EIFR, PCIFR):
            d[address] &= ~value  # writing 1 clears a flag
            return
        if address == TCNT0: self.timers[0].count = value; return
        if address == TCNT2: self.timers[2].count = value; return
        if address == OCR0A: self.timers[0].write_ocr(0, value); return
        if address == OCR0B: self.timers[0].write_ocr(1, value); return
        if address == OCR2A: self.timers[2].write_ocr(0, value); return
        if address == OCR2B: self.timers[2].write_ocr(1, value); return
        if address in (TCNT1H, OCR1AH, OCR1BH, ICR1H):
            self.temp16 = value
            return
        if address in (TCNT1L, OCR1AL, OCR1BL, ICR1L):
            full = (self.temp16 << 8) | value
            if address == TCNT1L: self.timers[1].count = full
            elif address == OCR1AL: self.timers[1].write_ocr(0, full)
            elif address == OCR1BL: self.timers[1].write_ocr(1, full)
            else: self.timers[1].icr = full
            return
        if address == SREG:
            if value & I and not d[SREG] & I:
                self.interrupt_delay = self.enable_delay  # as after SEI, one more instruction runs before an interrupt
            d[SREG] = value
            return
        if address == UDR0:
            self.uart_write(value)
            return
        if address == UCSR0B and not self.uart_double_buffered:
            self.simavr_ucsrb_write(value)
            return
        if address in (UBRR0L,) and not self.uart_double_buffered:
            d[address] = value
            ubrr = (d[UBRR0H] << 8 | d[UBRR0L]) & 0xFFF
            self.sim_cycles_per_byte = (ubrr + 1) * (8 if d[UCSR0A] & 0x02 else 16) * 11
            return
        if address == UCSR0A:
            d[UCSR0A] = (d[UCSR0A] & ~0x03 | value & 0x03) & ~(value & 0x40)  # TXC cleared by writing 1
            return
        if address == ADCSRA:
            old = d[ADCSRA]
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
            d[ADCSRA] = new
            if not old & 0x40 and new & 0x40 and new & 0x80:
                prescale = [2, 2, 4, 8, 16, 32, 64, 128][new & 7]
                self.adc_done_at = self.cycles + (25 if self.adc_first else 13) * prescale
            return
        if address in (TCCR0B, TCCR1B, TCCR2B):
            timer = self.timers[{TCCR0B: 0, TCCR1B: 1, TCCR2B: 2}[address]]
            if (d[address] ^ value) & 7:
                timer.accumulator = 0  # the prescaler starts over when the clock changes
            d[address] = value
            return
        if address == EECR:
            d[EECR] = value
            address_e = (d[EEARH] << 8 | d[EEARL]) & 0x3FF
            if value & 0x01:
                d[EEDR] = self.eeprom[address_e]
                d[EECR] &= ~0x01
            if value & 0x02 and value & 0x04 or value & 0x02:
                if value & 0x02:
                    self.eeprom[address_e] = d[EEDR]
                    d[EECR] &= ~0x06
            return
        d[address] = value

    # ---------------------------------------------------------------- serial

    # simavr's UART, for comparing with it: TXEN on at reset, UDRE cleared when TXEN goes off, a "pump" that raises
    # UDRE once per byte time (11 bits: it counts a parity bit) while bytes are queued or UDRIE is on

    def simavr_udr_write(self, value):
        d = self.data
        d[UCSR0A] &= ~0x20
        if d[UCSR0B] & 0x08:
            self.serial_out.append(value)
            self.sim_tx_count += 1
            if self.sim_pump_at is None:
                self.sim_pump_at = self.cycles + self.sim_cycles_per_byte

    def simavr_pump(self):
        d = self.data
        when = self.sim_pump_at
        self.sim_pump_at = None
        if self.sim_tx_count:
            if self.sim_tx_count == 1:
                d[UCSR0A] |= 0x40
            self.sim_tx_count -= 1
        if self.sim_tx_count:
            d[UCSR0A] &= ~0x20
            self.sim_pump_at = when + self.sim_cycles_per_byte
        elif d[UCSR0B] & 0x08:
            d[UCSR0A] |= 0x20
            if d[UCSR0B] & 0x20:
                self.sim_pump_at = when + self.sim_cycles_per_byte

    def simavr_ucsrb_write(self, value):
        d = self.data
        old = d[UCSR0B]
        d[UCSR0B] = value
        if not old & 0x20 and value & 0x20 and value & 0x08 and self.sim_pump_at is None:
            d[UCSR0A] |= 0x20
        if old & 0x08 and not value & 0x08:
            d[UCSR0A] &= ~0x20

    def uart_frame_cycles(self):
        d = self.data
        ubrr = (d[UBRR0H] << 8 | d[UBRR0L]) & 0xFFF
        return (8 if d[UCSR0A] & 0x02 else 16) * (ubrr + 1) * 10

    def uart_write(self, value):
        d = self.data
        if not self.uart_double_buffered:
            self.simavr_udr_write(value)
            return
        if self.uart_tx_busy_until > self.cycles:
            self.uart_tx_pending = value
            d[UCSR0A] &= ~0x20  # UDRE: the buffer is full
        else:
            self.serial_out.append(value)
            self.uart_tx_busy_until = self.cycles + self.uart_frame_cycles()
            d[UCSR0A] |= 0x20
        d[UCSR0A] &= ~0x40

    def uart_update(self):
        d = self.data
        if not self.uart_double_buffered:
            while self.sim_pump_at is not None and self.cycles >= self.sim_pump_at:
                self.simavr_pump()
        elif self.uart_tx_busy_until and self.cycles >= self.uart_tx_busy_until:
            if self.uart_tx_pending is not None:
                self.serial_out.append(self.uart_tx_pending)
                self.uart_tx_pending = None
                self.uart_tx_busy_until += self.uart_frame_cycles()
                d[UCSR0A] |= 0x20
            else:
                self.uart_tx_busy_until = 0
                d[UCSR0A] |= 0x40  # TXC
        if self.serial_in and d[UCSR0B] & 0x10 and self.cycles >= self.uart_rx_next and not d[UCSR0A] & 0x80:
            d[UDR0] = self.serial_in.pop(0)
            d[UCSR0A] |= 0x80
            self.uart_rx_next = self.cycles + self.uart_frame_cycles()

    # ---------------------------------------------------------------- peripherals

    def adc_update(self):
        if self.adc_done_at is not None and self.cycles >= self.adc_done_at:
            d = self.data
            channel = d[ADMUX] & 0x0F
            volts = self.pin_volts[14 + channel] if channel < 6 else (1.1 if channel == 14 else 0)
            reference = self.vcc if d[ADMUX] & 0x40 else self.vcc
            value = max(0, min(1023, int(volts / reference * 1024)))
            if d[ADMUX] & 0x20:  # left adjusted
                value <<= 6
            d[ADCL], d[ADCH] = value & 0xFF, (value >> 8) & 0xFF
            d[ADCSRA] = (d[ADCSRA] & ~0x40) | 0x10
            self.adc_done_at = None
            self.adc_first = False

    def external_interrupts(self):
        d = self.data
        for k, pin in ((0, 2), (1, 3)):
            level = self.pin_high[pin] if not (d[DDRD] >> pin) & 1 else bool((d[PORTD] >> pin) & 1)
            sense = (d[EICRA] >> (2 * k)) & 3
            previous = self.int_previous[k]
            fire = (sense == 1 and level != previous) or (sense == 2 and previous and not level) or (sense == 3 and level and not previous)
            if fire:
                d[EIFR] |= 1 << k
            self.int_previous[k] = level

    def pending_interrupt(self):
        d = self.data
        if d[EIMSK] & 1 and d[EIFR] & 1: return INT0_V, (EIFR, 1)
        if d[EIMSK] & 2 and d[EIFR] & 2 and not (d[EICRA] & 0x0C == 0): return INT1_V, (EIFR, 2)
        if d[EIMSK] & 2 and d[EIFR] & 2: return INT1_V, (EIFR, 2)
        for timer in (self.timers[2], self.timers[1], self.timers[0]):
            pass
        checks = [(TIMSK2, TIFR2, 2, TIMER2_COMPA_V), (TIMSK2, TIFR2, 4, TIMER2_COMPB_V), (TIMSK2, TIFR2, 1, TIMER2_OVF_V),
                  (TIMSK1, TIFR1, 2, TIMER1_COMPA_V), (TIMSK1, TIFR1, 4, TIMER1_COMPB_V), (TIMSK1, TIFR1, 1, TIMER1_OVF_V),
                  (TIMSK0, TIFR0, 2, TIMER0_COMPA_V), (TIMSK0, TIFR0, 4, TIMER0_COMPB_V), (TIMSK0, TIFR0, 1, TIMER0_OVF_V)]
        for mask, flags, bit, vector in checks:
            if d[mask] & bit and d[flags] & bit:
                return vector, (flags, bit)
        if d[UCSR0B] & 0x80 and d[UCSR0A] & 0x80: return USART_RX_V, None
        if d[UCSR0B] & 0x20 and d[UCSR0A] & 0x20: return USART_UDRE_V, None
        if d[UCSR0B] & 0x40 and d[UCSR0A] & 0x40: return USART_TX_V, (UCSR0A, 0x40)
        if d[ADCSRA] & 0x08 and d[ADCSRA] & 0x10: return ADC_V, (ADCSRA, 0x10)
        return None, None

    # ---------------------------------------------------------------- CPU helpers

    def push(self, value):
        sp = self.data[SPL] | self.data[SPH] << 8
        self.data[sp] = value & 0xFF
        sp = (sp - 1) & 0xFFFF
        self.data[SPL], self.data[SPH] = sp & 0xFF, sp >> 8

    def pop(self):
        sp = ((self.data[SPL] | self.data[SPH] << 8) + 1) & 0xFFFF
        self.data[SPL], self.data[SPH] = sp & 0xFF, sp >> 8
        return self.data[sp]

    def push_pc(self, pc):
        self.push(pc & 0xFF)
        self.push(pc >> 8)

    def pop_pc(self):
        high = self.pop()
        low = self.pop()
        return (high << 8 | low) & 0x3FFF

    def set_flags(self, mask, values):
        self.data[SREG] = (self.data[SREG] & ~mask | values) & 0xFF

    def flags_add(self, a, b, carry, result):
        r = result & 0xFF
        h = ((a & b) | (b & ~r) | (~r & a)) & 0x08
        c = ((a & b) | (b & ~r) | (~r & a)) & 0x80
        v = ((a & b & ~r) | (~a & ~b & r)) & 0x80
        n = r & 0x80
        f = (C if c else 0) | (Z if r == 0 else 0) | (N if n else 0) | (V if v else 0) | (H if h else 0)
        f |= S if bool(n) != bool(v) else 0
        self.set_flags(C | Z | N | V | S | H, f)
        return r

    def flags_sub(self, a, b, result, keep_z=False):
        r = result & 0xFF
        h = ((~a & b) | (b & r) | (r & ~a)) & 0x08
        c = ((~a & b) | (b & r) | (r & ~a)) & 0x80
        v = ((a & ~b & ~r) | (~a & b & r)) & 0x80
        n = r & 0x80
        f = (C if c else 0) | (N if n else 0) | (V if v else 0) | (H if h else 0)
        f |= S if bool(n) != bool(v) else 0
        if keep_z:
            f |= Z if (r == 0 and self.data[SREG] & Z) else 0
        else:
            f |= Z if r == 0 else 0
        self.set_flags(C | Z | N | V | S | H, f)
        return r

    def flags_logic(self, r):
        r &= 0xFF
        n = r & 0x80
        self.set_flags(Z | N | V | S, (Z if r == 0 else 0) | (N if n else 0) | (S if n else 0))
        return r

    def instruction_words(self, op):
        # 32-bit instructions: LDS, STS, JMP, CALL
        return 2 if (op & 0xFE0F) in (0x9000, 0x9200) or (op & 0xFE0E) in (0x940C, 0x940E) else 1

    # ---------------------------------------------------------------- one instruction

    def step(self):
        """Runs one instruction (or takes an interrupt); returns cycles used"""
        if self.interrupt_delay == 0 and self.data[SREG] & I:
            vector, clear = self.pending_interrupt()
            if vector is not None:
                if clear:
                    self.data[clear[0]] &= ~clear[1]
                self.push_pc(self.pc)
                self.data[SREG] &= ~I
                self.pc = vector * 2
                self.tick(self.interrupt_cycles)
                return self.interrupt_cycles
        if self.interrupt_delay:
            self.interrupt_delay -= 1
        cycles = self.execute()
        self.tick(cycles)
        return cycles

    def tick(self, cycles):
        self.cycles += cycles
        for timer in self.timers:
            timer.advance(cycles)
        self.uart_update()
        self.adc_update()
        self.external_interrupts()

    def execute(self):
        d = self.data
        op = self.flash[self.pc]
        pc = self.pc
        self.pc = (pc + 1) & 0x3FFF
        rd5 = (op >> 4) & 0x1F
        rr5 = (op & 0x0F) | ((op >> 5) & 0x10)
        rd4 = 16 + ((op >> 4) & 0x0F)
        k8 = (op & 0x0F) | ((op >> 4) & 0xF0)
        hi4 = op >> 12

        if op == 0x0000:
            return 1  # NOP
        if hi4 == 0x0:
            top = op & 0xFC00
            if top == 0x0C00:  # ADD
                a, b = d[rd5], d[rr5]
                d[rd5] = self.flags_add(a, b, 0, a + b)
                return 1
            if top == 0x0800:  # SBC
                a, b = d[rd5], d[rr5]
                c = d[SREG] & C
                d[rd5] = self.flags_sub(a, b, a - b - c, keep_z=True)
                return 1
            if top == 0x0400:  # CPC
                a, b = d[rd5], d[rr5]
                c = d[SREG] & C
                self.flags_sub(a, b, a - b - c, keep_z=True)
                return 1
            if (op & 0xFF00) == 0x0100:  # MOVW
                dd, rr = ((op >> 4) & 0x0F) * 2, (op & 0x0F) * 2
                d[dd], d[dd + 1] = d[rr], d[rr + 1]
                return 1
            if (op & 0xFF00) == 0x0200:  # MULS
                a = d[16 + ((op >> 4) & 0x0F)]; b = d[16 + (op & 0x0F)]
                a = a - 256 if a & 0x80 else a; b = b - 256 if b & 0x80 else b
                return self.multiply_result(a * b, False)
            if (op & 0xFF88) == 0x0300:  # MULSU
                a = d[16 + ((op >> 4) & 7)]; b = d[16 + (op & 7)]
                a = a - 256 if a & 0x80 else a
                return self.multiply_result(a * b, False)
            if (op & 0xFF88) == 0x0308:  # FMUL
                a = d[16 + ((op >> 4) & 7)]; b = d[16 + (op & 7)]
                return self.multiply_result(a * b, True)
            if (op & 0xFF88) == 0x0380:  # FMULS
                a = d[16 + ((op >> 4) & 7)]; b = d[16 + (op & 7)]
                a = a - 256 if a & 0x80 else a; b = b - 256 if b & 0x80 else b
                return self.multiply_result(a * b, True)
            if (op & 0xFF88) == 0x0388:  # FMULSU
                a = d[16 + ((op >> 4) & 7)]; b = d[16 + (op & 7)]
                a = a - 256 if a & 0x80 else a
                return self.multiply_result(a * b, True)
        if hi4 == 0x1:
            top = op & 0xFC00
            if top == 0x1C00:  # ADC
                a, b = d[rd5], d[rr5]
                c = d[SREG] & C
                d[rd5] = self.flags_add(a, b, c, a + b + c)
                return 1
            if top == 0x1800:  # SUB
                a, b = d[rd5], d[rr5]
                d[rd5] = self.flags_sub(a, b, a - b)
                return 1
            if top == 0x1400:  # CP
                a, b = d[rd5], d[rr5]
                self.flags_sub(a, b, a - b)
                return 1
            if top == 0x1000:  # CPSE
                if d[rd5] == d[rr5]:
                    return self.skip()
                return 1
        if hi4 == 0x2:
            top = op & 0xFC00
            if top == 0x2000:  # AND
                d[rd5] = self.flags_logic(d[rd5] & d[rr5]); return 1
            if top == 0x2400:  # EOR
                d[rd5] = self.flags_logic(d[rd5] ^ d[rr5]); return 1
            if top == 0x2800:  # OR
                d[rd5] = self.flags_logic(d[rd5] | d[rr5]); return 1
            if top == 0x2C00:  # MOV
                d[rd5] = d[rr5]; return 1
        if hi4 == 0x3:  # CPI
            a = d[rd4]
            self.flags_sub(a, k8, a - k8)
            return 1
        if hi4 == 0x4:  # SBCI
            a = d[rd4]
            c = d[SREG] & C
            d[rd4] = self.flags_sub(a, k8, a - k8 - c, keep_z=True)
            return 1
        if hi4 == 0x5:  # SUBI
            a = d[rd4]
            d[rd4] = self.flags_sub(a, k8, a - k8)
            return 1
        if hi4 == 0x6:  # ORI
            d[rd4] = self.flags_logic(d[rd4] | k8); return 1
        if hi4 == 0x7:  # ANDI
            d[rd4] = self.flags_logic(d[rd4] & k8); return 1
        if (op & 0xD000) == 0x8000:  # LDD/STD with displacement (Y or Z), including LD/ST Y, Z
            q = (op & 0x07) | ((op >> 7) & 0x18) | ((op >> 8) & 0x20)
            base = 28 if op & 0x08 else 30
            address = (d[base] | d[base + 1] << 8) + q
            if op & 0x0200:
                self.write(address, d[rd5])
            else:
                d[rd5] = self.read(address)
            return 2
        if hi4 == 0x9:
            return self.execute_9(op, rd5, rr5, pc)
        if hi4 == 0xB:  # IN / OUT
            a = ((op >> 5) & 0x30) | (op & 0x0F)
            if op & 0x0800:
                self.write(a + 0x20, d[rd5])
            else:
                d[rd5] = self.read(a + 0x20)
            return 1
        if hi4 == 0xC:  # RJMP
            k = op & 0x0FFF
            if k & 0x800: k -= 0x1000
            self.pc = (self.pc + k) & 0x3FFF
            return 2
        if hi4 == 0xD:  # RCALL
            k = op & 0x0FFF
            if k & 0x800: k -= 0x1000
            self.push_pc(self.pc)
            self.pc = (self.pc + k) & 0x3FFF
            return 3
        if hi4 == 0xE:  # LDI
            d[rd4] = k8
            return 1
        if hi4 == 0xF:
            if (op & 0xF800) == 0xF000 or (op & 0xF800) == 0xF400:  # BRBS / BRBC
                bit = 1 << (op & 7)
                k = (op >> 3) & 0x7F
                if k & 0x40: k -= 0x80
                taken = bool(d[SREG] & bit) == ((op & 0x0400) == 0)
                if taken:
                    self.pc = (self.pc + k) & 0x3FFF
                    return 2
                return 1
            if (op & 0xFE08) == 0xF800:  # BLD
                bit = op & 7
                if d[SREG] & T: d[rd5] |= 1 << bit
                else: d[rd5] &= ~(1 << bit) & 0xFF
                return 1
            if (op & 0xFE08) == 0xFA00:  # BST
                bit = op & 7
                self.set_flags(T, T if d[rd5] >> bit & 1 else 0)
                return 1
            if (op & 0xFE08) == 0xFC00:  # SBRC
                if not (d[rd5] >> (op & 7)) & 1:
                    return self.skip()
                return 1
            if (op & 0xFE08) == 0xFE00:  # SBRS
                if (d[rd5] >> (op & 7)) & 1:
                    return self.skip()
                return 1
        raise RuntimeError(f"unknown opcode {op:04x} at {pc:04x}")

    def multiply_result(self, product, fractional):
        d = self.data
        if fractional:
            c = (product >> 15) & 1
            product <<= 1
        else:
            c = (product >> 15) & 1
        product &= 0xFFFF
        d[0], d[1] = product & 0xFF, product >> 8
        self.set_flags(C | Z, (C if c else 0) | (Z if product == 0 else 0))
        return 2

    def skip(self):
        op = self.flash[self.pc]
        words = self.instruction_words(op)
        self.pc = (self.pc + words) & 0x3FFF
        return 1 + words

    def execute_9(self, op, rd5, rr5, pc):
        d = self.data
        if (op & 0xFC00) == 0x9C00:  # MUL
            return self.multiply_result(d[rd5] * d[rr5], False)
        if (op & 0xFE00) in (0x9000, 0x9200):
            store = op & 0x0200
            mode = op & 0x0F
            if mode == 0x0:  # LDS / STS
                address = self.flash[self.pc]
                self.pc = (self.pc + 1) & 0x3FFF
                if store: self.write(address, d[rd5])
                else: d[rd5] = self.read(address)
                return 2
            if not store and mode in (0x4, 0x5):  # LPM Rd, Z / Z+
                z = d[30] | d[31] << 8
                word = self.flash[(z >> 1) & 0x3FFF]
                d[rd5] = (word >> 8) if z & 1 else (word & 0xFF)
                if mode == 0x5:
                    z = (z + 1) & 0xFFFF
                    d[30], d[31] = z & 0xFF, z >> 8
                return 3
            if not store and mode in (0x6, 0x7):  # ELPM: no RAMPZ on this chip
                z = d[30] | d[31] << 8
                word = self.flash[(z >> 1) & 0x3FFF]
                d[rd5] = (word >> 8) if z & 1 else (word & 0xFF)
                if mode == 0x7:
                    z = (z + 1) & 0xFFFF
                    d[30], d[31] = z & 0xFF, z >> 8
                return 3
            if mode == 0xF:  # PUSH / POP
                if store: self.push(d[rd5])
                else: d[rd5] = self.pop()
                return 2
            pointers = {0x1: (30, 1), 0x2: (30, -1), 0x9: (28, 1), 0xA: (28, -1), 0xC: (26, 0), 0xD: (26, 1), 0xE: (26, -1)}
            if mode in pointers:
                base, change = pointers[mode]
                p = d[base] | d[base + 1] << 8
                if change < 0:
                    p = (p - 1) & 0xFFFF
                if store:
                    self.write(p, d[rd5])
                else:
                    d[rd5] = self.read(p)
                if change > 0:
                    p = (p + 1) & 0xFFFF
                d[base], d[base + 1] = p & 0xFF, p >> 8
                return 2
            if mode in (0x4, 0x5, 0x6, 0x7) and store:  # XCH, LAS, LAC, LAT (not on this chip)
                return 1
        if (op & 0xFE00) == 0x9400:
            low = op & 0x0F
            if low == 0x0:  # COM
                r = (~d[rd5]) & 0xFF
                n = r & 0x80
                self.set_flags(C | Z | N | V | S, C | (Z if r == 0 else 0) | (N if n else 0) | (S if n else 0))
                d[rd5] = r
                return 1
            if low == 0x1:  # NEG
                a = d[rd5]
                r = (-a) & 0xFF
                h = (r | a) & 0x08
                v = r == 0x80
                n = r & 0x80
                f = (C if r != 0 else 0) | (Z if r == 0 else 0) | (N if n else 0) | (V if v else 0) | (H if h else 0)
                f |= S if bool(n) != bool(v) else 0
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
                r = (a >> 1) | (a & 0x80)
                return self.shift_flags(rd5, a, r)
            if low == 0x6:  # LSR
                a = d[rd5]
                return self.shift_flags(rd5, a, a >> 1)
            if low == 0x7:  # ROR
                a = d[rd5]
                r = (a >> 1) | (0x80 if d[SREG] & C else 0)
                return self.shift_flags(rd5, a, r)
            if low == 0xA:  # DEC
                r = (d[rd5] - 1) & 0xFF
                v = r == 0x7F
                n = r & 0x80
                self.set_flags(Z | N | V | S, (Z if r == 0 else 0) | (N if n else 0) | (V if v else 0) | (S if bool(n) != v else 0))
                d[rd5] = r
                return 1
            if (op & 0x000E) == 0x000C:  # JMP (32-bit)
                k = self.flash[self.pc] | ((op & 0x01F0) << 13) | ((op & 1) << 16)
                self.pc = k & 0x3FFF
                return 3
            if (op & 0x000E) == 0x000E:  # CALL
                k = self.flash[self.pc] | ((op & 0x01F0) << 13) | ((op & 1) << 16)
                self.push_pc((self.pc + 1) & 0x3FFF)
                self.pc = k & 0x3FFF
                return 4
            if (op & 0xFF8F) == 0x9408:  # BSET
                self.data[SREG] |= 1 << ((op >> 4) & 7)
                if (op >> 4) & 7 == 7:
                    self.interrupt_delay = self.enable_delay
                return 1
            if (op & 0xFF8F) == 0x9488:  # BCLR
                self.data[SREG] &= ~(1 << ((op >> 4) & 7)) & 0xFF
                return 1
            if op == 0x9508:  # RET
                self.pc = self.pop_pc()
                return 4
            if op == 0x9518:  # RETI
                self.pc = self.pop_pc()
                self.data[SREG] |= I
                self.interrupt_delay = self.enable_delay
                return 4
            if op in (0x9588, 0x95A8, 0x9598):  # SLEEP, WDR, BREAK
                return 1
            if op == 0x95C8:  # LPM (R0)
                z = d[30] | d[31] << 8
                word = self.flash[(z >> 1) & 0x3FFF]
                d[0] = (word >> 8) if z & 1 else (word & 0xFF)
                return 3
            if op == 0x95E8:  # SPM: self-programming is not emulated
                return 1
            if op == 0x9409:  # IJMP
                self.pc = d[30] | d[31] << 8
                return 2
            if op == 0x9509:  # ICALL
                self.push_pc(self.pc)
                self.pc = d[30] | d[31] << 8
                return 3
        if (op & 0xFF00) in (0x9600, 0x9700):  # ADIW / SBIW
            dd = 24 + ((op >> 3) & 0x06)
            k = (op & 0x0F) | ((op >> 2) & 0x30)
            a = d[dd] | d[dd + 1] << 8
            if (op & 0xFF00) == 0x9600:
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
        if (op & 0xFC00) == 0x9800:  # CBI SBIC SBI SBIS
            a = 0x20 + ((op >> 3) & 0x1F)
            bit = op & 7
            kind = op & 0x0300
            if kind == 0x0000:  # CBI
                self.write_bit(a, bit, False)
                return 2
            if kind == 0x0200:  # SBI
                self.write_bit(a, bit, True)
                return 2
            value = (self.read(a) >> bit) & 1
            if (kind == 0x0100 and not value) or (kind == 0x0300 and value):
                return self.skip()
            return 1
        raise RuntimeError(f"unknown opcode {op:04x} at {pc:04x}")

    def write_bit(self, address, bit, value):
        d = self.data
        if address in (PINB, PINC, PIND):
            if value:
                d[address + 2] ^= 1 << bit
            return
        if address in (TIFR0, TIFR1, TIFR2, EIFR, PCIFR):
            if value:
                d[address] &= ~(1 << bit)
            return
        current = self.read(address)
        self.write(address, (current | (1 << bit)) if value else (current & ~(1 << bit)))

    def shift_flags(self, rd, a, r):
        r &= 0xFF
        c = a & 1
        n = bool(r & 0x80)
        v = n != bool(c)
        self.set_flags(C | Z | N | V | S, (C if c else 0) | (Z if r == 0 else 0) | (N if n else 0) | (V if v else 0) | (S if n != v else 0))
        self.data[rd] = r
        return 1

    # ---------------------------------------------------------------- pins

    def pin_outputs(self):
        """For each of the 20 pins: None (input) or True/False (driven high or low); timer outputs override PORT"""
        d = self.data
        result = []
        overrides = {}
        for timer in self.timers:
            for unit in (0, 1):
                if (d[timer.tccra] >> (6 - 2 * unit)) & 3:
                    overrides[timer.pins[unit]] = timer.output[unit]
        for pin, (pinreg, bit) in enumerate(PIN_PORTS):
            if (d[pinreg + 1] >> bit) & 1:
                result.append(overrides.get(pin, bool((d[pinreg + 2] >> bit) & 1)))
            else:
                result.append(None)
        return result

    def pullups(self):
        d = self.data
        return [not (d[pinreg + 1] >> bit) & 1 and bool((d[pinreg + 2] >> bit) & 1) for pinreg, bit in PIN_PORTS]

    def run(self, cycles):
        end = self.cycles + cycles
        while self.cycles < end:
            self.step()


def load(path):
    return AVR(open(path, 'rb').read())
