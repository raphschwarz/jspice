"""Reference waveforms for JSpice's analog engine from ngspice.

Each case is a circuit as JSpice netlist parts (an example from Examples.swift, read from the source, or one defined
here). It is translated into a SPICE deck whose device models are JSpice's own equations (Shockley diodes, Ebers-Moll
transistors, level-1 MOSFETs, JSpice's op-amp macromodel as behavioural sources, junction capacitances and stored
charge as SPICE's), run in ngspice with tight tolerances, and the probed node voltages are sampled. A case may run at
another temperature than the parts' nominal 27 °C. The result, Tests/CircuitKitTests/Fixtures/spice-reference.json,
is what SpiceCrossCheckTests compares JSpice with: so differences measure JSpice's numerics, not its models.

python3 crosscheck.py            # writes the fixture (needs ngspice)
python3 crosscheck.py --ac       # small-signal: ngspice's operating point and .ac sweep, spice-ac-reference.json
"""
import json, math, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '../..'))
SOURCES = os.path.join(ROOT, 'Sources/CircuitKit')
FIXTURE = os.path.join(ROOT, 'Tests/CircuitKitTests/Fixtures/spice-reference.json')
AC_FIXTURE = os.path.join(ROOT, 'Tests/CircuitKitTests/Fixtures/spice-ac-reference.json')
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
    """A netlist example's parts, read from Examples.swift (its parts may come from a function of the examples, given
    one of them: the Fuzz Face's guitar)"""
    source = open(os.path.join(SOURCES, 'Examples.swift')).read()
    start = source.index('id: "%s"' % example_id)
    end = source.index('scopes:', start)
    text = source[start:end]
    shared = re.search(r'(\w+)\(guitar: (NetlistPart\(.*?\]\))\)', text, re.S)
    if shared:
        body = source[source.index('static func %s(' % shared.group(1)):]
        body = body[:body.index('\n    }\n')]
        text = body.replace('guitar,', shared.group(2) + ',', 1)
    parts = []
    for match in re.finditer(r'NetlistPart\(kind: \.(\w+), name: "(\w+)"(.*?)connections: (\[[^\]]*\])\)', text, re.S):
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

def spice_deck(parts, duration, probes, step, temperature=27):
    lines, models = spice_elements(parts, temperature=temperature)
    data = tempfile.mktemp(suffix='.txt')
    lines += models
    lines += ['.tran %.6g %.12g 0 %.6g uic' % (step, duration, step), '.control', 'run',
              'wrdata %s %s' % (data, ' '.join('v(%s)' % net(x) for x in probes)), 'quit', '.endc', '.end']
    return '\n'.join(lines) + '\n', data

def spice_elements(parts, ac_source=None, temperature=27):
    """The deck's options and element lines, and its models; `ac_source` is the source driven in an AC analysis"""
    # JSpice's thermal voltage, 25.852 mV, is kT/q at 300.00 K: its nominal 27 °C
    nominal = VT / 8.617333262e-5 - 273.15
    lines = ['* JSpice cross-check', '.options reltol=1e-6 abstol=1e-13 vntol=1e-8 gmin=1e-12 method=gear maxord=2 itl4=200',
             '.options temp=%.4f tnom=%.4f' % (nominal + temperature - 27, nominal)]
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
                model = 'IS=%.12g N=%.12g TT=%.12g' % (max(param(p, 'saturationCurrent'), 1e-30), max(param(p, 'emission'), 0.1),
                                                      param(p, 'tt'))
            models.append('.model D_%s D(%s CJO=%.12g VJ=1 M=0.5)' % (n, model, param(p, 'cj0')))
            lines.append('D%s %s %s D_%s' % (n, pin('anode'), pin('cathode'), n))
        elif k in ('npn', 'pnp'):
            models.append('.model Q_%s %s(IS=%.12g BF=%.12g BR=1 CJE=%.12g VJE=0.75 MJE=0.33 CJC=%.12g VJC=0.75 MJC=0.33 TF=%.12g)' % (
                n, k.upper(), max(param(p, 'saturationCurrent'), 1e-20), max(param(p, 'beta'), 1), param(p, 'cje'), param(p, 'cjc'),
                param(p, 'tf')))
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
        elif k in ('triode', 'pentode'):
            # Koren's equations, as Tubes.swift: plate (and screen) current, grid current, the electrode capacitances
            g, pl, ca = pin('grid'), pin('plate'), pin('cathode')
            mu, ex, kg1, kp, kvb, rgi = (param(p, x) for x in ('mu', 'ex', 'kg1', 'kp', 'kvb', 'rgi'))
            vg, vp = 'V(%s,%s)' % (g, ca), 'V(%s,%s)' % (pl, ca)
            if k == 'triode':
                e1 = '%s/%.12g*ln(1+exp(%.12g*(1/%.12g+%s/sqrt(%.12g+%s*%s))))' % (vp, kp, kp, mu, vg, kvb, vp, vp)
                lines.append('B%s_p %s %s I=2*pwr(max(%s,0),%.12g)/%.12g' % (n, pl, ca, e1, ex, kg1))
            else:
                sc = pin('screen')
                vs = 'max(V(%s,%s),1e-3)' % (sc, ca)
                e1 = '%s/%.12g*ln(1+exp(%.12g*(1/%.12g+%s/%s)))' % (vs, kp, kp, mu, vg, vs)
                lines.append('B%s_p %s %s I=2*pwr(max(%s,0),%.12g)/%.12g*atan(max(%s,0)/%.12g)' % (n, pl, ca, e1, ex, kg1, vp, kvb))
                lines.append('B%s_s %s %s I=pwr(max(%s+V(%s,%s)/%.12g,0),%.12g)/%.12g' % (n, sc, ca, vg, sc, ca, mu, ex, param(p, 'kg2')))
            lines.append('B%s_g %s %s I=pwr(max(%s,0),1.5)/%.12g' % (n, g, ca, vg, rgi))
            for key, a, b in (('cgk', g, ca), ('cgp', g, pl), ('cpk', pl, ca)):
                if param(p, key) > 0:
                    lines.append('C%s_%s %s %s %.12g IC=0' % (n, key, a, b, param(p, key)))
        elif k == 'transformer':
            # two coupled inductors with their windings' resistances
            lp, ratio, coupling = max(param(p, 'inductance'), 1e-12), param(p, 'ratio'), min(max(param(p, 'coupling'), 0.01), 1)
            px, sx = 'n_%s_px' % n, 'n_%s_sx' % n
            lines.append('R%s_p %s %s %.12g' % (n, pin('p1'), px, max(param(p, 'rp'), 1e-6)))
            lines.append('L%s_p %s %s %.12g IC=0' % (n, px, pin('p2'), lp))
            lines.append('R%s_s %s %s %.12g' % (n, sx, pin('s1'), max(param(p, 'rs'), 1e-6)))
            lines.append('L%s_s %s %s %.12g IC=0' % (n, sx, pin('s2'), lp * ratio ** 2))
            lines.append('K%s L%s_p L%s_s %.12g' % (n, n, n, coupling))
        elif k in ('speaker', 'probe'):
            pass
        else:
            raise ValueError('no SPICE equivalent for %s' % k)
        if n == ac_source:
            # held at its offset for the operating point (as JSpice settles with the source's amplitude at zero)
            if k == 'acVoltage':
                lines[-1] = 'V%s %s %s DC %.12g' % (n, pin('plus'), pin('minus'), param(p, 'offset'))
            lines[-1] += ' AC 1'
    return lines, models

def run_ngspice(parts, duration, probes, step, temperature=27):
    deck, data = spice_deck(parts, duration, probes, step, temperature)
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
# Koren's 12AX7 (Element.swift's triode defaults) and 6L6GC
TUBE_12AX7 = dict(mu=100, ex=1.4, kg1=1060, kp=600, kvb=300, rgi=2000, cgk=2.3e-12, cgp=2.4e-12, cpk=0.9e-12)
TUBE_6L6GC = MODELS[('pentode', '6L6GC')]
OUTPUT_TRANSFORMER = MODELS[('transformer', 'Output 8 kΩ : 8 Ω')]

def triode_stage(amplitude):
    """A 12AX7 common-cathode stage, as in a guitar amp's first stage: 250 V through 100 kΩ, 1.5 kΩ and 22 µF at the
    cathode, 1 MΩ grid leak"""
    return [
        P('dcVoltage', 'VB', dict(plus='bplus', minus='GND'), voltage=250),
        P('acVoltage', 'VIN', dict(plus='in', minus='GND'), amplitude=amplitude, frequency=1000),
        P('capacitor', 'CIN', dict(a='in', b='grid'), capacitance=22e-9),
        P('resistor', 'RG', dict(a='grid', b='GND'), resistance=1e6),
        P('triode', 'V1', dict(grid='grid', plate='plate', cathode='cath'), **TUBE_12AX7),
        P('resistor', 'RP', dict(a='bplus', b='plate'), resistance=100_000),
        P('resistor', 'RK', dict(a='cath', b='GND'), resistance=1500),
        P('capacitor', 'CK', dict(a='cath', b='GND'), capacitance=22e-6),
        P('capacitor', 'COUT', dict(a='plate', b='out'), capacitance=22e-9),
        P('resistor', 'RL', dict(a='out', b='GND'), resistance=1e6)]

PENTODE_STAGE = [
    # a single-ended 6L6GC into an output transformer and an 8 Ω speaker, cathode biased
    P('dcVoltage', 'VB', dict(plus='bplus', minus='GND'), voltage=300),
    P('acVoltage', 'VIN', dict(plus='in', minus='GND'), amplitude=8, frequency=1000),
    P('capacitor', 'CIN', dict(a='in', b='grid'), capacitance=100e-9),
    P('resistor', 'RG', dict(a='grid', b='GND'), resistance=470_000),
    P('pentode', 'V1', dict(grid='grid', plate='plate', cathode='cath', screen='screen'), **TUBE_6L6GC),
    P('resistor', 'RS', dict(a='bplus', b='screen'), resistance=470),
    P('resistor', 'RK', dict(a='cath', b='GND'), resistance=250),
    P('capacitor', 'CK', dict(a='cath', b='GND'), capacitance=100e-6),
    P('transformer', 'T1', dict(p1='bplus', p2='plate', s1='spk', s2='GND'), **OUTPUT_TRANSFORMER),
    P('resistor', 'RSPK', dict(a='spk', b='GND'), resistance=8)]

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
    dict(id='hot-common-emitter', note='the common-emitter amplifier at 70 °C: more saturation current, less base voltage',
         duration=0.1, probes=['col', 'base'], temperature=70, parts=None),
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
    dict(id='triode', note='12AX7 common-cathode stage overdriven by 3 V at 1 kHz: grid current and clipping', duration=0.03,
         probes=['plate', 'cath'], parts=triode_stage(3)),
    dict(id='pentode', note='single-ended 6L6GC into an output transformer and 8 Ω, 8 V at 1 kHz on the grid', duration=0.03,
         probes=['plate', 'spk'], parts=PENTODE_STAGE),
    dict(id='transformer', note='mains transformer, 230 V : 12 V, into a half-wave rectifier, 470 µF and 100 Ω', duration=0.06,
         probes=['sec', 'out'], parts=[
        P('acVoltage', 'V1', dict(plus='mains', minus='GND'), amplitude=325, frequency=50),
        P('transformer', 'T1', dict(p1='mains', p2='GND', s1='sec', s2='GND'), **MODELS[('transformer', 'Mains 230 V : 12 V')]),
        P('diode', 'D1', dict(anode='sec', cathode='out')),
        P('capacitor', 'C1', dict(a='out', b='GND'), capacitance=470e-6),
        P('resistor', 'R1', dict(a='out', b='GND'), resistance=100)]),
    dict(id='fuzz', example='fuzz', note='the Fuzz Face example (two BC108s)', duration=0.03, probes=['c2', 'out']),
    dict(id='rectifier-1n4001', note='a 1N4001 rectifying 2 kHz: its 5.7 µs of stored charge lets current back for a moment',
         duration=0.002, probes=['out'], parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=10, frequency=2000),
        P('diode', 'D1', dict(anode='in', cathode='out'), **MODELS[('diode', '1N4001')]),
        P('capacitor', 'C1', dict(a='out', b='GND'), capacitance=1e-6),
        P('resistor', 'R1', dict(a='out', b='GND'), resistance=1000)]),
    dict(id='overdrive', example='overdrive', note='the diode-clipper overdrive example (TL072, 1N4148s)', duration=0.02,
         probes=['amp', 'clip']),
]

def case_parts(id):
    return next(c for c in CASES if c['id'] == id)['parts']

next(c for c in CASES if c['id'] == 'hot-common-emitter')['parts'] = case_parts('common-emitter')

# Small-signal (AC) analysis: ngspice's operating point and .ac sweep; JSpice settles the circuit with the driven
# source's amplitude at zero and linearises it there
AC_CASES = [
    dict(id='rc-lowpass', note='RC low-pass, 159 Hz corner', source='V1', settle=0.01, probes=['out'], parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=1, frequency=100),
        P('resistor', 'R1', dict(a='in', b='out'), resistance=1000),
        P('capacitor', 'C1', dict(a='out', b='GND'), capacitance=1e-6)]),
    dict(id='rlc-resonance', note='series RLC, 1.59 kHz resonance with a Q of 10', source='V1', settle=0.01, probes=['cap'], parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=1, frequency=100),
        P('resistor', 'R1', dict(a='in', b='l'), resistance=10),
        P('inductor', 'L1', dict(a='l', b='cap'), inductance=0.01),
        P('capacitor', 'C1', dict(a='cap', b='GND'), capacitance=1e-6)]),
    dict(id='zener-ripple', note='5.1 V Zener regulator: ripple through its dynamic resistance', source='V1', settle=0.01,
         probes=['out'], parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=4, offset=12, frequency=100),
        P('resistor', 'R1', dict(a='in', b='out'), resistance=470),
        P('zener', 'D1', dict(anode='GND', cathode='out'), breakdown=5.1),
        P('resistor', 'R2', dict(a='out', b='GND'), resistance=1000)]),
    dict(id='common-emitter', note='NPN common-emitter amplifier with a bypassed emitter', source='VIN', settle=0.3,
         probes=['col', 'base'], parts=list(case_parts('common-emitter'))),
    dict(id='jfet', note='N-JFET common-source stage biased at -0.75 V', source='VG', settle=0.001, probes=['drain'], parts=[
        P('dcVoltage', 'VDD', dict(plus='vdd', minus='GND'), voltage=12),
        P('acVoltage', 'VG', dict(plus='gate', minus='GND'), amplitude=0.5, offset=-0.75, frequency=1000),
        P('resistor', 'RD', dict(a='vdd', b='drain'), resistance=2200),
        P('resistor', 'RL', dict(a='drain', b='out'), resistance=1000),
        P('capacitor', 'CL', dict(a='out', b='GND'), capacitance=10e-9),
        P('njfet', 'J1', dict(gate='gate', drain='drain', source='GND'))]),
    dict(id='opamp-inverting', note='TL072 inverting amplifier, gain 10, out to its 3 MHz bandwidth', source='VIN', settle=0.001,
         probes=['out'], fstop=1e7, parts=list(case_parts('opamp-inverting'))),
    dict(id='sallen-key', note='TL072 Sallen-Key low-pass, 1.59 kHz, Q 0.5', source='VIN', settle=0.01, probes=['out'], parts=[
        P('acVoltage', 'VIN', dict(plus='in', minus='GND'), amplitude=1, frequency=1000),
        P('resistor', 'R1', dict(a='in', b='a'), resistance=10_000),
        P('resistor', 'R2', dict(a='a', b='b'), resistance=10_000),
        P('capacitor', 'C1', dict(a='a', b='out'), capacitance=10e-9),
        P('capacitor', 'C2', dict(a='b', b='GND'), capacitance=10e-9),
        P('opAmp', 'U1', dict(minus='out', plus='b', out='out'), **TL072)]),
    dict(id='triode', note='12AX7 common-cathode stage: gain and the Miller roll-off', source='VIN', settle=1.0,
         probes=['plate', 'out'], fstop=1e6, parts=triode_stage(0.1)),
    dict(id='output-transformer', note='6L6GC into its output transformer: the low end from the primary inductance',
         source='VIN', settle=1.0, probes=['spk'], parts=PENTODE_STAGE),
    dict(id='fuzz', example='fuzz', note='the Fuzz Face example (two BC108s), small signals', source='GTR', settle=0.5,
         probes=['c2', 'out']),
    dict(id='overdrive', example='overdrive', note='the overdrive example below clipping', source='VIN', settle=0.5,
         probes=['amp', 'clip']),
]

def run_ngspice_ac(parts, source, probes, fstart, fstop, per_decade):
    lines, models = spice_elements(parts, ac_source=source)
    data = tempfile.mktemp(suffix='.txt')
    deck = '\n'.join(lines + models + ['.ac dec %d %.6g %.6g' % (per_decade, fstart, fstop), '.control', 'run',
                                       'wrdata %s %s' % (data, ' '.join('v(%s)' % net(x) for x in probes)),
                                       'quit', '.endc', '.end']) + '\n'
    with tempfile.NamedTemporaryFile('w', suffix='.cir', delete=False) as f:
        f.write(deck)
    result = subprocess.run(['ngspice', '-b', f.name], capture_output=True, text=True, timeout=600)
    if not os.path.exists(data) or 'aborted' in result.stdout + result.stderr:
        sys.exit('ngspice failed:\n' + deck + result.stdout[-3000:] + result.stderr[-3000:])
    rows = [list(map(float, line.split())) for line in open(data) if line.strip()]
    os.unlink(data)
    # each probe: frequency, real part, imaginary part
    frequencies = [row[0] for row in rows]
    values = {x: [(row[3 * i + 1], row[3 * i + 2]) for row in rows] for i, x in enumerate(probes)}
    return frequencies, values

# Noise: ngspice's .noise at an output, with each part's thermal and shot noise (no flicker noise), around the same
# operating point
NOISE_CASES = [
    dict(id='divider-noise', note='two 1 kΩ resistors and 1 nF: 4kT · 500 Ω, rolling off at 318 kHz', source='V1', settle=0.001,
         output='out', parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=1, frequency=1000),
        P('resistor', 'R1', dict(a='in', b='out'), resistance=1000),
        P('resistor', 'R2', dict(a='out', b='GND'), resistance=1000),
        P('capacitor', 'C1', dict(a='out', b='GND'), capacitance=1e-9)]),
    dict(id='common-emitter-noise', note='the common-emitter amplifier: shot noise of its collector and base currents',
         source='VIN', settle=0.3, output='col', parts=None),
    dict(id='jfet-noise', note='the N-JFET stage: channel noise', source='VG', settle=0.001, output='drain', parts=None),
    dict(id='diode-noise', note='a diode carrying 0.43 mA through 10 kΩ: its shot noise against the resistor\'s', source='V1',
         settle=0.001, output='a', parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=1, offset=5, frequency=1000),
        P('resistor', 'R1', dict(a='in', b='a'), resistance=10_000),
        P('diode', 'D1', dict(anode='a', cathode='GND'))]),
]

def run_ngspice_noise(parts, source, output, fstart, fstop, per_decade):
    lines, models = spice_elements(parts, ac_source=source)
    data = tempfile.mktemp(suffix='.txt')
    deck = '\n'.join(lines + models + ['.noise v(%s) V%s dec %d %.6g %.6g' % (net(output), source, per_decade, fstart, fstop),
                                       '.control', 'run', 'setplot noise1', 'wrdata %s onoise_spectrum' % data,
                                       'quit', '.endc', '.end']) + '\n'
    with tempfile.NamedTemporaryFile('w', suffix='.cir', delete=False) as f:
        f.write(deck)
    result = subprocess.run(['ngspice', '-b', f.name], capture_output=True, text=True, timeout=600)
    if not os.path.exists(data) or 'aborted' in result.stdout + result.stderr:
        sys.exit('ngspice failed:\n' + deck + result.stdout[-3000:] + result.stderr[-3000:])
    rows = [list(map(float, line.split())) for line in open(data) if line.strip()]
    os.unlink(data)
    return [row[0] for row in rows], [row[1] for row in rows]

def ac_main():
    out = []
    for case in AC_CASES:
        parts = example_parts(case['example']) if 'example' in case else case['parts']
        frequencies, values = run_ngspice_ac(parts, case['source'], case['probes'], case.get('fstart', 1), case.get('fstop', 1e5), 5)
        probes = []
        for name in case['probes']:
            part, terminal = next((p['name'], t) for p in parts for t, n in p['connections'].items() if n == name)
            gains = [math.hypot(re, im) for re, im in values[name]]
            phases = [math.degrees(math.atan2(im, re)) for re, im in values[name]]
            probes.append(dict(net=name, part=part, terminal=terminal, gain_db=[round(20 * math.log10(max(g, 1e-30)), 6) for g in gains],
                               phase_deg=[round(p, 5) for p in phases]))
        entry = dict(id=case['id'], note=case['note'], source=case['source'], settle=case['settle'],
                     frequencies=[round(f, 9) for f in frequencies], probes=probes)
        if 'example' in case:
            entry['example'] = case['example']
        else:
            entry['parts'] = parts
        out.append(entry)
        summary = ', '.join('%s %.1f..%.1f dB' % (p['net'], min(p['gain_db']), max(p['gain_db'])) for p in probes)
        print('%-16s %s' % (case['id'], summary))
    noise = []
    for case in NOISE_CASES:
        parts = case['parts'] or (case_parts('common-emitter') if case['id'].startswith('common') else
                                  next(c for c in AC_CASES if c['id'] == 'jfet')['parts'])
        frequencies, density = run_ngspice_noise(parts, case['source'], case['output'], 10, 1e6, 5)
        part, terminal = next((p['name'], t) for p in parts for t, n in p['connections'].items() if n == case['output'])
        noise.append(dict(id=case['id'], note=case['note'], source=case['source'], settle=case['settle'], part=part, terminal=terminal,
                          frequencies=[round(f, 9) for f in frequencies], density=[float('%.9g' % d) for d in density], parts=parts))
        print('%-20s %.3g..%.3g nV/√Hz' % (case['id'], min(density) * 1e9, max(density) * 1e9))
    json.dump(dict(generator='tools/spice-reference/crosscheck.py --ac', ngspice=subprocess.run(
        ['ngspice', '-v'], capture_output=True, text=True).stdout.split('\n')[1].strip(' *'), cases=out, noise=noise),
        open(AC_FIXTURE, 'w'), indent=1)

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
        time, waves = run_ngspice(parts, case['duration'], case['probes'], step, case.get('temperature', 27))
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
        if 'temperature' in case:
            entry['temperature'] = case['temperature']
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
    ac_main() if '--ac' in sys.argv else main()
