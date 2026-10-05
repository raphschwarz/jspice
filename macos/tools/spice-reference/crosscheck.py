"""Reference waveforms for JSpice's analog engine from ngspice.

Each case is a circuit as JSpice netlist parts (an example from Examples.swift, read from the source, or one defined
here). It is translated into a SPICE deck whose device models are JSpice's own equations (Shockley diodes, Ebers-Moll
transistors, level-1 MOSFETs, JSpice's op-amp macromodel as behavioural sources), run in ngspice with tight
tolerances, and the probed node voltages are sampled. The one addition: 1 pF on each junction, which JSpice's models do
not have, so that ngspice's switching edges are not infinitely fast (it gives up on those); at these circuits' time
scales it changes nothing measurable. The result, Tests/CircuitKitTests/Fixtures/spice-reference.json,
is what SpiceCrossCheckTests compares JSpice with: so differences measure JSpice's numerics, not its models.

python3 crosscheck.py            # writes the fixture (needs ngspice)
"""
import json, math, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '../..'))
SOURCES = os.path.join(ROOT, 'Sources/CircuitKit')
FIXTURE = os.path.join(ROOT, 'Tests/CircuitKitTests/Fixtures/spice-reference.json')
VT = 0.025852  # Simulator.thermalVoltage
LED_FORWARD = [1.9, 2.2, 3.0, 2.0, 3.0]  # LEDColor: red, green, blue, yellow, white

# MARK: - Reading JSpice's sources

def number(text):
    return float(text.replace('_', ''))

def swift_dictionary(text):
    """["a": 1, "b": 2e-3] -> dict"""
    return {k: number(v) for k, v in re.findall(r'"(\w+)":\s*(-?[\d._eE+-]+)', text)}

def cases_of(block):
    """The `case .x, .y:` blocks of a Swift switch body, as {kind: text}"""
    result = {}
    parts = re.split(r'\n\s*case ((?:\.\w+,?\s*)+):', '\n' + block)
    for i in range(1, len(parts), 2):
        for kind in re.findall(r'\.(\w+)', parts[i]):
            result[kind] = parts[i + 1]
    return result

element = open(os.path.join(SOURCES, 'Element.swift')).read()
params_body = element[element.index('public var params: [ParamSpec] {'):element.index('/// One component on the schematic')]
DEFAULTS = {kind: {k: number(v) for k, v in re.findall(r'ParamSpec\("(\w+)",\s*"[^"]*",[^\n]*?default: (-?[\d._eE+-]+)', text)}
            for kind, text in cases_of(params_body).items()}
models_body = element[element.index('public var models: [PartModel] {'):]
models_body = models_body[:models_body.index('\n    }\n')]
MODELS = {}
for kind, text in cases_of(models_body).items():
    for name, values in re.findall(r'PartModel\(name: "([^"]+)".*?values: (\[[^\]]*\])', text, re.S):
        MODELS[(kind, name)] = swift_dictionary(values)

def example_parts(example_id):
    """A netlist example's parts, read from Examples.swift"""
    source = open(os.path.join(SOURCES, 'Examples.swift')).read()
    start = source.index('id: "%s"' % example_id)
    end = source.index('scopes:', start)
    parts = []
    for match in re.finditer(r'NetlistPart\(kind: \.(\w+), name: "(\w+)"(.*?)connections: (\[[^\]]*\])\)', source[start:end], re.S):
        kind, name, middle, connections = match.groups()
        params = {}
        model = re.search(r'model\(\.(\w+), "([^"]+)"\)', middle)
        if model: params.update(MODELS[(model.group(1), model.group(2))])
        literal = re.search(r'params: (\[[^\]]*\])', middle)
        if literal: params.update(swift_dictionary(literal.group(1)))
        parts.append(dict(kind=kind, name=name, params=params,
                          connections=dict(re.findall(r'"(\w+)":\s*"([^"]+)"', connections))))
    return parts

def param(part, key):
    if key in part['params']: return part['params'][key]
    return DEFAULTS.get(part['kind'], {}).get(key, 0.0)

# MARK: - SPICE

def net(name):
    return '0' if name in ('GND', '0') else 'n_' + re.sub(r'\W', '_', name)

def spice_deck(parts, duration, probes, step):
    lines = ['* JSpice cross-check', '.options reltol=1e-6 abstol=1e-13 vntol=1e-8 gmin=1e-12 method=gear maxord=2 itl4=200',
             # JSpice's thermal voltage, 25.852 mV, is kT/q at 300.00 K
             '.options temp=%.4f tnom=%.4f' % (VT / 8.617333262e-5 - 273.15, VT / 8.617333262e-5 - 273.15)]
    models = []
    for p in parts:
        k, n, c = p['kind'], p['name'], p['connections']
        pin = lambda t: net(c.get(t, 'nc_%s_%s' % (n, t)))
        if k == 'resistor':
            lines.append('R%s %s %s %.12g' % (n, pin('a'), pin('b'), max(param(p, 'resistance'), 1e-9)))
        elif k == 'potentiometer':
            total = max(param(p, 'resistance'), 1e-3)
            position = min(1, max(0, param(p, 'position')))
            if param(p, 'taper') >= 0.5: position = (10 ** (2 * position) - 1) / 99
            floor = total * 1e-4 + 1e-3
            lines.append('R%s_u %s %s %.12g' % (n, pin('a'), pin('wiper'), max(total * position, floor)))
            lines.append('R%s_l %s %s %.12g' % (n, pin('wiper'), pin('b'), max(total * (1 - position), floor)))
        elif k == 'capacitor':
            lines.append('C%s %s %s %.12g IC=%.12g' % (n, pin('a'), pin('b'), param(p, 'capacitance'), param(p, 'initialVoltage')))
        elif k == 'inductor':
            lines.append('L%s %s %s %.12g IC=0' % (n, pin('a'), pin('b'), max(param(p, 'inductance'), 1e-15)))
        elif k == 'dcVoltage':
            lines.append('V%s %s %s DC %.12g' % (n, pin('plus'), pin('minus'), param(p, 'voltage')))
        elif k == 'acVoltage':
            lines.append('V%s %s %s SIN(%.12g %.12g %.12g 0 0 %.12g)' % (n, pin('plus'), pin('minus'), param(p, 'offset'),
                         param(p, 'amplitude'), param(p, 'frequency'), param(p, 'phase')))
        elif k == 'squareVoltage':
            period = 1 / param(p, 'frequency')
            edge = period * 1e-6
            lines.append('V%s %s %s PULSE(%.12g %.12g 0 %.6g %.6g %.12g %.12g)' % (n, pin('plus'), pin('minus'),
                         param(p, 'low'), param(p, 'high'), edge, edge, param(p, 'duty') * period - edge, period))
        elif k == 'currentSource':
            lines.append('I%s %s %s DC %.12g' % (n, pin('a'), pin('b'), param(p, 'current')))
        elif k in ('diode', 'led', 'zener'):
            if k == 'led':
                nvt = 2 * VT
                model = 'IS=%.12g N=2' % (0.01 / math.exp(LED_FORWARD[int(param(p, 'color'))] / nvt))
            elif k == 'zener':
                model = 'IS=1e-14 N=1 BV=%.12g IBV=5e-3' % abs(param(p, 'breakdown'))
            else:
                model = 'IS=%.12g N=%.12g' % (max(param(p, 'saturationCurrent'), 1e-30), max(param(p, 'emission'), 0.1))
            models.append('.model D_%s D(%s CJO=1p)' % (n, model))
            lines.append('D%s %s %s D_%s' % (n, pin('anode'), pin('cathode'), n))
        elif k in ('npn', 'pnp'):
            models.append('.model Q_%s %s(IS=%.12g BF=%.12g BR=1 CJE=1p CJC=1p)' % (n, k.upper(), max(param(p, 'saturationCurrent'), 1e-20),
                                                                   max(param(p, 'beta'), 1)))
            lines.append('Q%s %s %s %s Q_%s' % (n, pin('collector'), pin('base'), pin('emitter'), n))
        elif k in ('nmos', 'pmos'):
            threshold = param(p, 'threshold')
            models.append('.model M_%s %s(LEVEL=1 VTO=%.12g KP=%.12g LAMBDA=0.01)' % (
                n, k.upper(), threshold if k == 'nmos' else -threshold, param(p, 'beta')))
            lines.append('M%s %s %s %s %s M_%s L=1 W=1' % (n, pin('drain'), pin('gate'), pin('source'), pin('source'), n))
            lines.append('R%s_leak %s %s 1e9' % (n, pin('drain'), pin('source')))
        elif k == 'njfet':
            pinch = min(param(p, 'pinchOff'), -0.01)
            models.append('.model J_%s NJF(VTO=%.12g BETA=%.12g LAMBDA=0.01 IS=1e-30)' % (n, pinch, max(param(p, 'idss'), 1e-9) / pinch ** 2))
            lines.append('J%s %s %s %s J_%s' % (n, pin('drain'), pin('gate'), pin('source'), n))
            lines.append('R%s_leak %s %s 1e9' % (n, pin('drain'), pin('source')))
        elif k == 'opAmp':
            gain, limit, gbw = max(param(p, 'gain'), 1), max(param(p, 'limit'), 0.01), param(p, 'gbw')
            slew, offset = param(p, 'slewRate') * 1e6, param(p, 'offset')
            vd = '(v(%s)-v(%s)+%.12g)' % (pin('plus'), pin('minus'), offset)
            if gbw <= 0:
                lines.append('B%s %s 0 V=%.12g*tanh(%.12g*%s/%.12g)' % (n, pin('out'), limit, gain, vd, limit))
            else:
                w = 2 * math.pi * gbw
                tau = gain / w
                stage = 'n_%s_stage' % n
                drive = '%.12g*tanh(%s*%.12g/%.12g)' % (slew, vd, w, slew) if slew > 0 else '%.12g*%s' % (w, vd)
                bound = 3 * limit
                # the internal stage integrates the drive, a pole at gbw/gain; JSpice clamps it to three times the swing
                # after each step, here a steep smooth limit holds it there (a hard switch stalls ngspice)
                lines.append('B%s_drive 0 %s I=%s' % (n, stage, drive))
                lines.append('B%s_clamp %s 0 I=1e9*(0.01*ln(1+exp((v(%s)-%.12g)/0.01))-0.01*ln(1+exp((-v(%s)-%.12g)/0.01)))' % (
                    n, stage, stage, bound, stage, bound))
                lines.append('C%s_stage %s 0 1 IC=0' % (n, stage))
                lines.append('R%s_stage %s 0 %.12g' % (n, stage, tau))
                lines.append('B%s %s 0 V=%.12g*tanh(v(%s)/%.12g)' % (n, pin('out'), limit, stage, limit))
        elif k in ('speaker', 'probe'):
            pass
        else:
            raise ValueError('no SPICE equivalent for %s' % k)
    data = tempfile.mktemp(suffix='.txt')
    lines += models
    lines += ['.tran %.6g %.12g 0 %.6g uic' % (step, duration, step), '.control', 'run',
              'wrdata %s %s' % (data, ' '.join('v(%s)' % net(x) for x in probes)), 'quit', '.endc', '.end']
    return '\n'.join(lines) + '\n', data

def run_ngspice(parts, duration, probes, step):
    deck, data = spice_deck(parts, duration, probes, step)
    with tempfile.NamedTemporaryFile('w', suffix='.cir', delete=False) as f:
        f.write(deck)
    result = subprocess.run(['ngspice', '-b', f.name], capture_output=True, text=True, timeout=600)
    if not os.path.exists(data) or 'aborted' in result.stdout + result.stderr:
        sys.exit('ngspice failed:\n' + deck + result.stdout[-3000:] + result.stderr[-3000:])
    columns = [list(map(float, line.split())) for line in open(data) if line.strip()]
    os.unlink(data)
    time = [row[0] for row in columns]
    waves = {x: [row[2 * i + 1] for row in columns] for i, x in enumerate(probes)}
    return time, waves

def interpolate(time, values, t):
    lo, hi = 0, len(time) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if time[mid] <= t: lo = mid
        else: hi = mid
    if time[hi] == time[lo]: return values[lo]
    f = (t - time[lo]) / (time[hi] - time[lo])
    return values[lo] + f * (values[hi] - values[lo])

# MARK: - The cases

def P(kind, name, connections, **params):
    return dict(kind=kind, name=name, params=params, connections=connections)

TL072 = MODELS[('opAmp', 'TL072')]

CASES = [
    dict(id='rc-step', note='RC low-pass, 1 ms time constant, on a 100 Hz square wave', duration=0.03, probes=['out'], parts=[
        P('squareVoltage', 'V1', dict(plus='in', minus='GND'), high=5, low=0, frequency=100, duty=0.5),
        P('resistor', 'R1', dict(a='in', b='out'), resistance=1000),
        P('capacitor', 'C1', dict(a='out', b='GND'), capacitance=1e-6)]),
    dict(id='rlc-ring', note='series RLC ringing at 1.59 kHz, Q of 10', duration=0.012, probes=['cap'], parts=[
        P('squareVoltage', 'V1', dict(plus='in', minus='GND'), high=1, low=0, frequency=100, duty=0.5),
        P('resistor', 'R1', dict(a='in', b='l'), resistance=10),
        P('inductor', 'L1', dict(a='l', b='cap'), inductance=0.01),
        P('capacitor', 'C1', dict(a='cap', b='GND'), capacitance=1e-6)]),
    dict(id='rectifier', note='half-wave rectifier into 100 µF and 1 kΩ, 50 Hz', duration=0.08, probes=['out'], parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=10, frequency=50),
        P('diode', 'D1', dict(anode='in', cathode='out')),
        P('capacitor', 'C1', dict(a='out', b='GND'), capacitance=100e-6),
        P('resistor', 'R1', dict(a='out', b='GND'), resistance=1000)]),
    dict(id='zener', note='5.1 V Zener regulator fed with 12 V and 4 V of ripple', duration=0.04, probes=['out'], parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=4, offset=12, frequency=100),
        P('resistor', 'R1', dict(a='in', b='out'), resistance=470),
        P('zener', 'D1', dict(anode='GND', cathode='out'), breakdown=5.1),
        P('resistor', 'R2', dict(a='out', b='GND'), resistance=1000)]),
    dict(id='led', note='red LED through 220 Ω on a 100 Hz, 0-5 V square wave', duration=0.02, probes=['anode'], parts=[
        P('squareVoltage', 'V1', dict(plus='in', minus='GND'), high=5, low=0, frequency=100, duty=0.5),
        P('resistor', 'R1', dict(a='in', b='anode'), resistance=220),
        P('led', 'D1', dict(anode='anode', cathode='GND'), color=0)]),
    dict(id='common-emitter', note='NPN common-emitter amplifier, divider bias, 50 mV at 1 kHz in', duration=0.1,
         probes=['col', 'base'], parts=[
        P('dcVoltage', 'VCC', dict(plus='vcc', minus='GND'), voltage=12),
        P('resistor', 'RB1', dict(a='vcc', b='base'), resistance=47_000),
        P('resistor', 'RB2', dict(a='base', b='GND'), resistance=10_000),
        P('resistor', 'RC', dict(a='vcc', b='col'), resistance=4700),
        P('resistor', 'RE', dict(a='emi', b='GND'), resistance=1000),
        P('capacitor', 'CE', dict(a='emi', b='GND'), capacitance=10e-6),
        P('npn', 'Q1', dict(base='base', collector='col', emitter='emi'), beta=150),
        P('acVoltage', 'VIN', dict(plus='sig', minus='GND'), amplitude=0.05, frequency=1000),
        P('capacitor', 'CIN', dict(a='sig', b='base'), capacitance=1e-6)]),
    dict(id='astable', note='the blinker: a two-transistor astable multivibrator with LEDs, about 0.7 s a cycle',
         duration=3, probes=['c1', 'b1'], periodic=['c1', 'b1'], parts=[
        P('dcVoltage', 'VCC', dict(plus='vcc', minus='GND'), voltage=9),
        P('resistor', 'RC1', dict(a='vcc', b='l1'), resistance=470),
        P('led', 'D1', dict(anode='l1', cathode='c1'), color=0),
        P('resistor', 'RC2', dict(a='vcc', b='l2'), resistance=470),
        P('led', 'D2', dict(anode='l2', cathode='c2'), color=1),
        P('resistor', 'RB1', dict(a='vcc', b='b1'), resistance=47_000),
        P('resistor', 'RB2', dict(a='vcc', b='b2'), resistance=51_000),
        # C1 starts charged, holding Q2 off: the usual astable start, the same in both simulators (from rest both
        # transistors can saturate together and latch, or not, depending on numerical noise)
        P('capacitor', 'C1', dict(a='c1', b='b2'), capacitance=10e-6, initialVoltage=8),
        P('capacitor', 'C2', dict(a='c2', b='b1'), capacitance=10e-6),
        P('npn', 'Q1', dict(base='b1', collector='c1', emitter='GND')),
        P('npn', 'Q2', dict(base='b2', collector='c2', emitter='GND'))]),
    dict(id='cmos-inverter', note='CMOS inverter (level-1 MOSFETs) driven by a 1 kHz sine', duration=0.003, probes=['out'], parts=[
        P('dcVoltage', 'VDD', dict(plus='vdd', minus='GND'), voltage=5),
        P('acVoltage', 'VIN', dict(plus='in', minus='GND'), amplitude=2.5, offset=2.5, frequency=1000),
        P('pmos', 'M1', dict(gate='in', drain='out', source='vdd')),
        P('nmos', 'M2', dict(gate='in', drain='out', source='GND')),
        P('capacitor', 'CL', dict(a='out', b='GND'), capacitance=10e-9)]),
    dict(id='jfet', note='N-JFET common-source stage, gate swung ±0.5 V about -0.75 V', duration=0.004, probes=['drain'], parts=[
        P('dcVoltage', 'VDD', dict(plus='vdd', minus='GND'), voltage=12),
        P('acVoltage', 'VG', dict(plus='gate', minus='GND'), amplitude=0.5, offset=-0.75, frequency=1000),
        P('resistor', 'RD', dict(a='vdd', b='drain'), resistance=2200),
        P('njfet', 'J1', dict(gate='gate', drain='drain', source='GND'))]),
    dict(id='opamp-inverting', note='TL072 inverting amplifier, gain 10, 1 kHz', duration=0.004, probes=['out'], parts=[
        P('acVoltage', 'VIN', dict(plus='in', minus='GND'), amplitude=0.5, frequency=1000),
        P('resistor', 'R1', dict(a='in', b='inv'), resistance=10_000),
        P('resistor', 'R2', dict(a='inv', b='out'), resistance=100_000),
        P('opAmp', 'U1', dict(minus='inv', plus='GND', out='out'), **TL072)]),
    dict(id='opamp-fast', note='TL072 at gain 10 and 100 kHz, where its 3 MHz bandwidth shows', duration=6e-5, probes=['out'], parts=[
        P('acVoltage', 'VIN', dict(plus='in', minus='GND'), amplitude=0.5, frequency=100_000),
        P('resistor', 'R1', dict(a='in', b='inv'), resistance=10_000),
        P('resistor', 'R2', dict(a='inv', b='out'), resistance=100_000),
        P('opAmp', 'U1', dict(minus='inv', plus='GND', out='out'), **TL072)]),
    dict(id='triangle-lfo', note='integrator and Schmitt comparator (two TL072s): a 5 Hz triangle LFO', duration=2.5,
         probes=['tri', 'sq'], periodic=['tri', 'sq'], parts=[
        P('opAmp', 'U1', dict(minus='int', plus='GND', out='tri'), **TL072),
        P('resistor', 'R1', dict(a='sq', b='int'), resistance=100_000),
        P('capacitor', 'C1', dict(a='int', b='tri'), capacitance=1e-6),
        P('opAmp', 'U2', dict(minus='GND', plus='hys', out='sq'), **TL072),
        P('resistor', 'R2', dict(a='tri', b='hys'), resistance=50_000),
        P('resistor', 'R3', dict(a='hys', b='sq'), resistance=100_000)]),
    dict(id='fuzz', example='fuzz', note='the Fuzz Face example (two BC108s)', duration=0.03, probes=['c2', 'out']),
    dict(id='overdrive', example='overdrive', note='the diode-clipper overdrive example (TL072, 1N4148s)', duration=0.02,
         probes=['amp', 'clip']),
]

def rising_crossings(time, values):
    level = (max(values) + min(values)) / 2
    result = []
    for i in range(1, len(values)):
        if values[i - 1] < level <= values[i]:
            f = (level - values[i - 1]) / (values[i] - values[i - 1])
            result.append(time[i - 1] + f * (time[i] - time[i - 1]))
    return level, result

def main():
    out = []
    for case in CASES:
        parts = example_parts(case['example']) if 'example' in case else case['parts']
        samples = 400
        step = case['duration'] / 20_000
        time, waves = run_ngspice(parts, case['duration'], case['probes'], step)
        times = [case['duration'] * (k + 1) / samples for k in range(samples)]
        probes = []
        for name in case['probes']:
            # a terminal on the net, for JSpice to read it from
            part, terminal = next((p['name'], t) for p in parts for t, n in p['connections'].items() if n == name)
            entry = dict(net=name, part=part, terminal=terminal,
                         values=[round(interpolate(time, waves[name], t), 9) for t in times])
            if name in case.get('periodic', []):
                level, crossings = rising_crossings(time, waves[name])
                entry.update(level=level, crossings=[round(t, 9) for t in crossings])
            probes.append(entry)
        entry = dict(id=case['id'], note=case['note'], duration=case['duration'], times=[round(t, 12) for t in times],
                     probes=probes)
        if 'example' in case:
            entry['example'] = case['example']
        else:
            entry['parts'] = parts
        out.append(entry)
        summary = ', '.join('%s %.3g..%.3g V' % (p['net'], min(p['values']), max(p['values'])) for p in probes)
        print('%-16s %s' % (case['id'], summary))
    json.dump(dict(generator='tools/spice-reference/crosscheck.py', ngspice=subprocess.run(
        ['ngspice', '-v'], capture_output=True, text=True).stdout.split('\n')[1].strip(' *'), cases=out),
        open(FIXTURE, 'w'), indent=1)

if __name__ == '__main__':
    main()
