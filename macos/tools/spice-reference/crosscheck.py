"""Reference waveforms for JSpice's analog engine from ngspice.

Each case is a circuit as JSpice netlist parts (an example from Examples.swift, read from the source, or one defined
here). It is translated into a SPICE deck whose device models are JSpice's own equations (Shockley diodes, Ebers-Moll
transistors, level-1 MOSFETs, JSpice's op-amp macromodel as behavioural sources, junction capacitances and stored
charge as SPICE's), run in ngspice with tight tolerances, and the probed node voltages are sampled. A case may run at
another temperature than the parts' nominal 27 °C. The result, Tests/CircuitKitTests/Fixtures/spice-reference.json,
is what SpiceCrossCheckTests compares JSpice with: so differences measure JSpice's numerics, not its models.

python3 crosscheck.py            # writes the fixture (needs ngspice)
python3 crosscheck.py --ac       # small-signal: ngspice's operating point and .ac sweep, spice-ac-reference.json
python3 crosscheck.py --devices  # devices at DC: ngspice's .dc sweeps of transistors' currents, spice-device-reference.json
python3 crosscheck.py --netlists # SPICE decks as written (controlled sources, subcircuits), which JSpice imports and runs,
                                 # spice-netlist-reference.json

Bipolar transistors are written as their whole Gummel-Poon card, the model JSpice implements as ngspice does, so a
manufacturer's card can be checked here as it is.
"""
import json, math, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '../..'))
SOURCES = os.path.join(ROOT, 'Sources/CircuitKit')
FIXTURE = os.path.join(ROOT, 'Tests/CircuitKitTests/Fixtures/spice-reference.json')
AC_FIXTURE = os.path.join(ROOT, 'Tests/CircuitKitTests/Fixtures/spice-ac-reference.json')
DEVICE_FIXTURE = os.path.join(ROOT, 'Tests/CircuitKitTests/Fixtures/spice-device-reference.json')
NETLIST_FIXTURE = os.path.join(ROOT, 'Tests/CircuitKitTests/Fixtures/spice-netlist-reference.json')
KQ = 1.38064852e-23 / 1.6021766208e-19  # ngspice's k/q (const.h)
NOMINAL_KELVIN = 300.15  # Simulator.nominalKelvin
VT = KQ * NOMINAL_KELVIN  # Simulator.thermalVoltage: kT/q at 27 °C
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
# a bipolar transistor's Gummel-Poon parameters are kept in a list of their own
gp_body = element[element.index('static let gummelPoonParams'):]
gp_body = gp_body[:gp_body.index('\n    ]\n')]
GP_DEFAULTS = {k: number(v) for k, v in re.findall(r'ParamSpec\("(\w+)",\s*"[^"]*",[^\n]*?default: (-?[\d._eE+-]+)', gp_body)}
for kind in ('npn', 'pnp'): DEFAULTS[kind].update(GP_DEFAULTS)
# and a diode's, past the parameters of each kind
diode_body = element[element.index('static let diodeCardParams'):]
diode_body = diode_body[:diode_body.index('\n    ]\n')]
DIODE_DEFAULTS = {k: number(v) for k, v in re.findall(r'ParamSpec\("(\w+)",\s*"[^"]*",[^\n]*?default: (-?[\d._eE+-]+)', diode_body)}
for kind in ('diode', 'zener', 'led'): DEFAULTS[kind].update(DIODE_DEFAULTS)
# a MOSFET's
mos_body = element[element.index('static let mosfetCardParams'):]
mos_body = mos_body[:mos_body.index('\n    ]\n')]
for kind in ('nmos', 'pmos'):
    DEFAULTS[kind].update({k: number(v) for k, v in re.findall(r'ParamSpec\("(\w+)",\s*"[^"]*",[^\n]*?default: (-?[\d._eE+-]+)', mos_body)})
# and a JFET's
jfet_body = element[element.index('static let jfetCardParams'):]
jfet_body = jfet_body[:jfet_body.index('\n    ]\n')]
for kind in ('njfet', 'pjfet'):
    DEFAULTS[kind].update({k: number(v) for k, v in re.findall(r'ParamSpec\("(\w+)",\s*"[^"]*",[^\n]*?default: (-?[\d._eE+-]+)', jfet_body)})
# GummelPoon.card: SPICE's names for JSpice's keys
GP_CARD = [('IS', 'saturationCurrent'), ('BF', 'beta'), ('NF', 'nf'), ('VAF', 'vaf'), ('IKF', 'ikf'), ('ISE', 'ise'), ('NE', 'ne'),
           ('BR', 'br'), ('NR', 'nr'), ('VAR', 'var'), ('IKR', 'ikr'), ('ISC', 'isc'), ('NC', 'nc'), ('NKF', 'nkf'),
           ('RB', 'rb'), ('IRB', 'irb'), ('RBM', 'rbm'), ('RE', 're'), ('RC', 'rc'),
           ('CJE', 'cje'), ('VJE', 'vje'), ('MJE', 'mje'), ('TF', 'tf'), ('XTF', 'xtf'), ('VTF', 'vtf'), ('ITF', 'itf'),
           ('CJC', 'cjc'), ('VJC', 'vjc'), ('MJC', 'mjc'), ('XCJC', 'xcjc'), ('TR', 'tr'), ('FC', 'fc'),
           ('XTB', 'xtb'), ('EG', 'eg'), ('XTI', 'xti'), ('KF', 'kf'), ('AF', 'af')]
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

def temperature_options(temperature):
    """ngspice at the circuit's temperature: JSpice's thermal voltage is kT/q with ngspice's constants, at 27 °C nominal"""
    return '.options temp=%.12g tnom=27' % temperature

def bipolar_card(p):
    """A transistor's whole Gummel-Poon card (RBM left out at 0, which is RB)"""
    words = []
    for name, key in GP_CARD:
        value = param(p, key)
        if name == 'RBM' and value <= 0: continue
        words.append('%s=%.12g' % (name, value))
    return ' '.join(words)

def diode_card(p, kind):
    """A diode's whole card (SpiceDiode.card): an LED's IS from its colour unless given, a Zener's BV its breakdown, BV,
    NBV and the knees left out at 0 (none, N, none)"""
    words = []
    for name, key in [('IS', 'saturationCurrent'), ('N', 'emission'), ('RS', 'rs'), ('CJO', 'cj0'), ('VJ', 'vj'), ('M', 'm'),
                      ('FC', 'fc'), ('TT', 'tt'), ('BV', 'breakdown' if kind == 'zener' else 'bv'), ('IBV', 'ibv'),
                      ('NBV', 'nbv'), ('IKF', 'ikf'), ('IKR', 'ikr'), ('EG', 'eg'), ('XTI', 'xti')]:
        value = param(p, key)
        if name == 'IS' and kind == 'led' and value <= 0:
            value = 0.01 / math.exp(LED_FORWARD[int(param(p, 'color'))] / (param(p, 'emission') * VT))
        if name in ('BV', 'NBV', 'IKF', 'IKR', 'RS') and value <= 0: continue
        words.append('%s=%.12g' % (name, abs(value)))
    return ' '.join(words)

def jfet_card(p):
    """A JFET's whole card (SpiceJFET.card): BETA from IDSS, with the gate at the source in saturation, and B's doping
    tail; BETATCE in place of BEX when given"""
    vto = min(param(p, 'pinchOff'), -0.01)
    b = param(p, 'b') if param(p, 'b') > 0 else 1
    b_factor = (1 - b) / (max(param(p, 'pb'), 0.01) - vto)
    beta = max(param(p, 'idss'), 1e-12) / (vto * vto * (b - b_factor * vto))
    words = ['VTO=%.12g' % vto, 'BETA=%.12g' % beta]
    for name, key in [('LAMBDA', 'lambda'), ('B', 'b'), ('RD', 'rd'), ('RS', 'rs'), ('IS', 'saturationCurrent'), ('CGS', 'cgs'),
                      ('CGD', 'cgd'), ('PB', 'pb'), ('FC', 'fc'), ('TCV', 'tcv'), ('XTI', 'xti'), ('EG', 'eg')]:
        words.append('%s=%.12g' % (name, param(p, key)))
    if param(p, 'betatce') != 0:
        words.append('BETATCE=%.12g' % param(p, 'betatce'))
    else:
        words.append('BEX=%.12g' % param(p, 'bex'))
    return ' '.join(words)

def mosfet_card(p, kind):
    """A MOSFET's whole level-1 card (SpiceMOSFET.cardText) for a transistor with W and L of 1 m: KP is its beta, the
    overlap capacitances per metre its own, TOX its gate oxide's capacitance"""
    t = -1 if kind == 'pmos' else 1
    words = ['LEVEL=1', 'VTO=%.12g' % (t * param(p, 'threshold')), 'KP=%.12g' % param(p, 'beta')]
    for name, key in [('LAMBDA', 'lambda'), ('GAMMA', 'gamma'), ('PHI', 'phi'), ('RD', 'rd'), ('RS', 'rs'),
                      ('IS', 'saturationCurrent'), ('CBD', 'cbd'), ('CBS', 'cbs'), ('PB', 'pb'), ('MJ', 'mj'), ('FC', 'fc'),
                      ('CGSO', 'cgs'), ('CGDO', 'cgd'), ('CGBO', 'cgb')]:
        words.append('%s=%.12g' % (name, param(p, key)))
    if param(p, 'cox') > 0:
        words.append('TOX=%.12g' % (3.9 * 8.854214871e-12 / param(p, 'cox')))
    return ' '.join(words)

def saturating_inductor(n, a, b, l0, isat, fraction):
    """An inductor whose core saturates, as JSpice has it: the flux λ, the integral of its voltage (a 1 F capacitor
    charged by it), and its current i(λ) = λ / Lsat − (1/Lsat − 1/L0) λsat tanh(λ / λsat)"""
    lsat = l0 * min(max(fraction, 1e-6), 1)
    saturation = l0 * isat
    flux = 'n_%s_flux' % n
    return ['G%s_flux 0 %s %s %s 1' % (n, flux, a, b), 'C%s_flux %s 0 1 IC=0' % (n, flux),
            'B%s %s %s I=V(%s)/%.12g-%.12g*tanh(V(%s)/%.12g)' % (n, a, b, flux, lsat, (1 / lsat - 1 / l0) * saturation, flux,
                                                             saturation)]

def spice_deck(parts, duration, probes, step, temperature=27):
    lines, models = spice_elements(parts, temperature=temperature)
    data = tempfile.mktemp(suffix='.txt')
    lines += models
    lines += ['.tran %.6g %.12g 0 %.6g uic' % (step, duration, step), '.control', 'run',
              'wrdata %s %s' % (data, ' '.join('v(%s)' % net(x) for x in probes)), 'quit', '.endc', '.end']
    return '\n'.join(lines) + '\n', data

def spice_elements(parts, ac_source=None, temperature=27):
    """The deck's options and element lines, and its models; `ac_source` is the source driven in an AC analysis"""
    lines = ['* JSpice cross-check', '.options reltol=1e-6 abstol=1e-13 vntol=1e-8 gmin=1e-12 method=gear maxord=2 itl4=200',
             temperature_options(temperature)]
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
            if param(p, 'saturationCurrent') > 0:
                lines += saturating_inductor(n, pin('a'), pin('b'), max(param(p, 'inductance'), 1e-15),
                                             param(p, 'saturationCurrent'), param(p, 'saturatedFraction'))
            else:
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
            # JSpice's current leaves its plus terminal: SPICE's n- (the current runs through the source from n+ to n-)
            lines.append('I%s %s %s DC %.12g' % (n, pin('minus'), pin('plus'), param(p, 'current')))
        elif k in ('diode', 'led', 'zener'):
            models.append('.model D_%s D(%s)' % (n, diode_card(p, k)))
            lines.append('D%s %s %s D_%s' % (n, pin('anode'), pin('cathode'), n))
        elif k in ('npn', 'pnp'):
            models.append('.model Q_%s %s(%s)' % (n, k.upper(), bipolar_card(p)))
            lines.append('Q%s %s %s %s Q_%s' % (n, pin('collector'), pin('base'), pin('emitter'), n))
        elif k in ('nmos', 'pmos'):
            models.append('.model M_%s %s(%s)' % (n, k.upper(), mosfet_card(p, k)))
            lines.append('M%s %s %s %s %s M_%s L=1 W=1' % (n, pin('drain'), pin('gate'), pin('source'), pin('source'), n))
        elif k in ('njfet', 'pjfet'):
            models.append('.model J_%s %s(%s)' % (n, 'NJF' if k == 'njfet' else 'PJF', jfet_card(p)))
            lines.append('J%s %s %s %s J_%s' % (n, pin('drain'), pin('gate'), pin('source'), n))
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
        elif k == 'transformer' and param(p, 'saturation') > 0:
            # as JSpice draws it: the windings' resistances, the leakage inductance, the magnetising inductance (which
            # saturates) and an ideal core, its secondary a voltage source of n / k times the primary's voltage and its
            # primary drawing n / k times the secondary's current
            lp, ratio, k_ = max(param(p, 'inductance'), 1e-12), param(p, 'ratio'), min(max(param(p, 'coupling'), 0.01), 1)
            x, y, e = 'n_%s_x' % n, 'n_%s_y' % n, 'n_%s_e' % n
            lines.append('R%s_p %s %s %.12g' % (n, pin('p1'), x, max(param(p, 'rp'), 1e-6)))
            lines.append('L%s_leak %s %s %.12g IC=0' % (n, x, y, (1 - k_ * k_) * lp))
            lm = k_ * k_ * lp
            lines += saturating_inductor(n + '_m', y, pin('p2'), lm, param(p, 'saturation') / lm, param(p, 'saturatedFraction'))
            sx = 'n_%s_sx' % n
            lines.append('E%s_core %s %s %s %s %.12g' % (n, e, pin('s2'), y, pin('p2'), ratio / k_))
            lines.append('V%s_sense %s %s DC 0' % (n, e, sx))
            lines.append('F%s_core %s %s V%s_sense %.12g' % (n, y, pin('p2'), n, ratio / k_))
            lines.append('R%s_s %s %s %.12g' % (n, sx, pin('s1'), max(param(p, 'rs'), 1e-6)))
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
# Test cards using every Gummel-Poon parameter JSpice implements (made up to be realistic, not any maker's part): the
# Early effect both ways, high-level injection, both leakage currents, a base resistance falling with the current,
# collector and emitter resistances, transit times rising with the current and VBC, a split CJC and the temperature
# exponents
GP_NPN = dict(saturationCurrent=1.8e-14, beta=250, nf=1.005, vaf=60, ikf=0.08, ise=5e-15, ne=1.6, br=6, nr=1.01, var=25, ikr=0.05,
              isc=4e-14, nc=1.3, rb=40, irb=1e-4, rbm=8, re=0.8, rc=1.5, cje=12e-12, vje=0.65, mje=0.35, tf=4e-10, xtf=20, vtf=3,
              itf=0.5, cjc=4e-12, vjc=0.45, mjc=0.3, xcjc=0.6, tr=5e-8, fc=0.8, xtb=1.5)
GP_PNP = dict(saturationCurrent=4e-14, beta=180, vaf=35, ikf=0.06, ise=2e-14, ne=1.7, br=4, var=15, isc=1e-13, nc=1.4, rb=60,
              irb=2e-4, rbm=15, re=1.2, rc=2.5, cje=15e-12, vje=0.7, mje=0.37, tf=6e-10, xtf=10, vtf=4, itf=0.3, cjc=6e-12, vjc=0.5,
              mjc=0.33, xcjc=0.5, tr=8e-8, fc=0.7, xtb=1.7)

# Test diode cards using every parameter JSpice implements (made up, not any maker's): a switching diode with a series
# resistance, a high-injection knee, a 3 ns transit time and an 80 V breakdown; a 6.2 V Zener with its own breakdown
# emission coefficient; a red LED with a series resistance
TEST_DIODE = dict(saturationCurrent=4e-9, emission=1.9, rs=0.6, cj0=4e-12, vj=0.7, m=0.4, fc=0.6, tt=3e-9, bv=80, ibv=1e-6,
                  ikf=0.05, xti=3.2, eg=1.11)
TEST_ZENER = dict(breakdown=6.2, saturationCurrent=2e-15, emission=1.05, rs=2, cj0=90e-12, vj=0.75, m=0.33, ibv=5e-3, nbv=1.8)
TEST_LED = dict(color=0, rs=4, cj0=20e-12, vj=1.8, m=0.35, ikr=1e-3, bv=5, ibv=1e-5)

# A test JFET card using every parameter JSpice implements (made up, not any maker's): B's doping tail, drain and source
# resistances, gate capacitances and the temperature coefficients
TEST_JFET = dict(pinchOff=-1.8, idss=6e-3, **{'lambda': 0.02}, b=0.85, rd=15, rs=8, saturationCurrent=2e-13, cgs=4e-12, cgd=1.5e-12,
                 pb=0.8, fc=0.6, tcv=2.5e-3, bex=-1.5, xti=3)

# Test MOSFET cards using every level-1 parameter JSpice implements (made up, not any maker's): the body effect (which
# shows in inverse mode, the bulk being the source), drain and source resistances, the bulk junctions' capacitances,
# the overlaps and Meyer's gate capacitances
TEST_NMOS = dict(threshold=2.1, beta=0.12, **{'lambda': 0.015}, rd=0.8, rs=0.5, saturationCurrent=2e-14, cbd=40e-12, cbs=20e-12,
                 pb=0.75, mj=0.45, fc=0.5, cgs=30e-12, cgd=8e-12, cgb=2e-12, cox=60e-12, gamma=0.4, phi=0.65)
TEST_PMOS = dict(threshold=1.8, beta=0.08, **{'lambda': 0.02}, rd=1.2, rs=0.8, saturationCurrent=5e-14, cbd=60e-12, cbs=30e-12,
                 pb=0.8, mj=0.5, cgs=40e-12, cgd=12e-12, cox=80e-12, gamma=0.3, phi=0.6)

def with_transistor(parts, name, **params):
    """The parts, with transistor `name` given these parameters instead of its own"""
    return [dict(p, params=dict(params)) if p['name'] == name else p for p in parts]

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
    dict(id='jfet-card', note='test JFET card: common-source stage driven at 20 kHz through 47 kΩ, from cut-off into gate '
         'conduction (B, RD, RS, IS, CGS, CGD)', duration=2e-4, probes=['drain', 'gate'], parts=[
        P('dcVoltage', 'VDD', dict(plus='vdd', minus='GND'), voltage=12),
        P('acVoltage', 'VG', dict(plus='in', minus='GND'), amplitude=1.4, offset=-0.7, frequency=20_000),
        P('resistor', 'RG', dict(a='in', b='gate'), resistance=47_000),
        P('resistor', 'RD', dict(a='vdd', b='drain'), resistance=3300),
        P('njfet', 'J1', dict(gate='gate', drain='drain', source='GND'), **TEST_JFET)]),
    dict(id='mosfet-card', note='test NMOS card: a switch driven at 50 kHz through 1 kΩ, its gate charging through the Miller '
         'plateau (Meyer, CGSO, CGDO, CBD, RD, RS)', duration=4e-5, probes=['drain', 'gate'], parts=[
        P('dcVoltage', 'VDD', dict(plus='vdd', minus='GND'), voltage=12),
        P('squareVoltage', 'VG', dict(plus='in', minus='GND'), high=5, low=0, frequency=50_000, duty=0.5),
        P('resistor', 'RG', dict(a='in', b='gate'), resistance=1000),
        P('resistor', 'RD', dict(a='vdd', b='drain'), resistance=1000),
        P('nmos', 'M1', dict(gate='gate', drain='drain', source='GND'), **TEST_NMOS)]),
    dict(id='saturating-inductor', note='a 1 H inductor saturating at 20 mA, driven through 10 Ω by a 50 Hz sine whose flux '
         'is half again its saturation: the current peaks sharply', duration=0.06, probes=['coil'], parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=10, frequency=50),
        P('resistor', 'R1', dict(a='in', b='coil'), resistance=10),
        P('inductor', 'L1', dict(a='coil', b='GND'), inductance=1, saturationCurrent=0.02, saturatedFraction=0.002)]),
    dict(id='saturating-transformer', note='a mains transformer into a rectifier load, its core saturating near the peak of a '
         '60 Hz primary voltage', duration=0.05, probes=['sec', 'pri'], parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=170, frequency=60),
        P('resistor', 'RS', dict(a='in', b='pri'), resistance=2),
        P('transformer', 'T1', dict(p1='pri', p2='GND', s1='sec', s2='GND'), inductance=5, ratio=0.0521739, coupling=0.995,
          rp=30, rs=0.5, saturation=0.5, saturatedFraction=0.01),
        P('resistor', 'RL', dict(a='sec', b='GND'), resistance=100)]),
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
    dict(id='gp-common-emitter', note='the common-emitter amplifier with a whole Gummel-Poon card (test card)', duration=0.1,
         probes=['col', 'base'], parts=None),
    dict(id='gp-hot-common-emitter', note='that at 70 °C: XTB, the leakage and the junction potentials at temperature',
         duration=0.1, probes=['col', 'base'], temperature=70, parts=None),
    dict(id='card-rectifier', note='a test diode card (RS, IKF, TT, CJO with VJ, M and FC) rectifying 200 kHz: its stored '
         'charge lets current back for a moment', duration=1.5e-5, probes=['out'], parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=5, frequency=200_000),
        P('resistor', 'RS', dict(a='in', b='a'), resistance=50),
        P('diode', 'D1', dict(anode='a', cathode='out'), **TEST_DIODE),
        P('capacitor', 'C1', dict(a='out', b='GND'), capacitance=10e-9),
        P('resistor', 'R1', dict(a='out', b='GND'), resistance=2000)]),
    dict(id='card-zener', note='a test Zener card (RS, NBV, CJO) regulating 12 V with 6 V of ripple through 220 Ω', duration=0.04,
         probes=['out'], parts=[
        P('acVoltage', 'V1', dict(plus='in', minus='GND'), amplitude=6, offset=12, frequency=100),
        P('resistor', 'R1', dict(a='in', b='out'), resistance=220),
        P('zener', 'D1', dict(anode='GND', cathode='out'), **TEST_ZENER),
        P('resistor', 'R2', dict(a='out', b='GND'), resistance=1000)]),
    dict(id='gp-switch', note='a saturating NPN switch at 20 kHz: stored charge (TF, TR) holds it on after the drive goes',
         duration=1.5e-4, probes=['col', 'base'], parts=[
        P('dcVoltage', 'VCC', dict(plus='vcc', minus='GND'), voltage=9),
        P('squareVoltage', 'VIN', dict(plus='in', minus='GND'), high=5, low=0, frequency=20_000, duty=0.5),
        P('resistor', 'RB', dict(a='in', b='base'), resistance=4700),
        P('resistor', 'RC', dict(a='vcc', b='col'), resistance=1000),
        P('npn', 'Q1', dict(base='base', collector='col', emitter='GND'), **GP_NPN)]),
    dict(id='gp-pnp', note='a PNP common-emitter stage with a whole Gummel-Poon card (test card), 30 mV at 1 kHz in',
         duration=0.1, probes=['col', 'base'], parts=[
        P('dcVoltage', 'VCC', dict(plus='vcc', minus='GND'), voltage=12),
        P('resistor', 'RB1', dict(a='vcc', b='base'), resistance=10_000),
        P('resistor', 'RB2', dict(a='base', b='GND'), resistance=47_000),
        P('resistor', 'RE', dict(a='vcc', b='emi'), resistance=1000),
        P('capacitor', 'CE', dict(a='emi', b='vcc'), capacitance=10e-6),
        P('resistor', 'RC', dict(a='col', b='GND'), resistance=4700),
        P('pnp', 'Q1', dict(base='base', collector='col', emitter='emi'), **GP_PNP),
        P('acVoltage', 'VIN', dict(plus='sig', minus='GND'), amplitude=0.03, frequency=1000),
        P('capacitor', 'CIN', dict(a='sig', b='base'), capacitance=1e-6)]),
]

def case_parts(id):
    return next(c for c in CASES if c['id'] == id)['parts']

next(c for c in CASES if c['id'] == 'hot-common-emitter')['parts'] = case_parts('common-emitter')
for _id in ('gp-common-emitter', 'gp-hot-common-emitter'):
    next(c for c in CASES if c['id'] == _id)['parts'] = with_transistor(case_parts('common-emitter'), 'Q1', **GP_NPN)

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
    dict(id='jfet-card', note='test JFET card: self-biased common-source stage fed from 100 kΩ, the Miller pole of CGD',
         source='VIN', settle=0.2, probes=['drain'], fstop=1e8, parts=[
        P('dcVoltage', 'VDD', dict(plus='vdd', minus='GND'), voltage=12),
        P('acVoltage', 'VIN', dict(plus='in', minus='GND'), amplitude=0.1, frequency=1000),
        P('resistor', 'RG', dict(a='in', b='gate'), resistance=100_000),
        P('resistor', 'RD', dict(a='vdd', b='drain'), resistance=2200),
        P('resistor', 'RS', dict(a='src', b='GND'), resistance=330),
        P('capacitor', 'CS', dict(a='src', b='GND'), capacitance=100e-6),
        P('njfet', 'J1', dict(gate='gate', drain='drain', source='src'), **TEST_JFET)]),
    dict(id='mosfet-card', note='test NMOS card: common-source stage biased at 2.4 V, fed from 10 kΩ, out to 100 MHz (Meyer '
         'and the overlaps, the Miller pole)', source='VIN', settle=1.5, probes=['drain'], fstop=1e8, parts=[
        P('dcVoltage', 'VDD', dict(plus='vdd', minus='GND'), voltage=12),
        P('acVoltage', 'VIN', dict(plus='sig', minus='GND'), amplitude=0.01, frequency=1000),
        P('resistor', 'RSIG', dict(a='sig', b='in'), resistance=10_000),
        P('capacitor', 'CIN', dict(a='in', b='gate'), capacitance=1e-6),
        P('resistor', 'R1', dict(a='vdd', b='gate'), resistance=100_000),
        P('resistor', 'R2', dict(a='gate', b='GND'), resistance=25_000),
        P('resistor', 'RD', dict(a='vdd', b='drain'), resistance=1000),
        P('nmos', 'M1', dict(gate='gate', drain='drain', source='GND'), **TEST_NMOS)]),
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
    dict(id='gp-common-emitter', note='the common-emitter amplifier with a whole Gummel-Poon card, out to 100 MHz: its base '
         'resistance, split CJC and transit time', source='VIN', settle=0.3, probes=['col', 'base'], fstop=1e8,
         parts=case_parts('gp-common-emitter')),
    dict(id='gp-pnp', note='the PNP stage with a whole Gummel-Poon card, out to 100 MHz', source='VIN', settle=0.3,
         probes=['col'], fstop=1e8, parts=case_parts('gp-pnp')),
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
    dict(id='gp-common-emitter-noise', note='the common-emitter amplifier with a whole Gummel-Poon card: shot noise, and the '
         'thermal noise of its base, collector and emitter resistances', source='VIN', settle=0.3, output='col', parts=None),
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
                                  case_parts('gp-common-emitter') if case['id'].startswith('gp-') else
                                  next(c for c in AC_CASES if c['id'] == 'jfet')['parts'])
        frequencies, density = run_ngspice_noise(parts, case['source'], case['output'], 10, 1e6, 5)
        part, terminal = next((p['name'], t) for p in parts for t, n in p['connections'].items() if n == case['output'])
        noise.append(dict(id=case['id'], note=case['note'], source=case['source'], settle=case['settle'], part=part, terminal=terminal,
                          frequencies=[round(f, 9) for f in frequencies], density=[float('%.9g' % d) for d in density], parts=parts))
        print('%-20s %.3g..%.3g nV/√Hz' % (case['id'], min(density) * 1e9, max(density) * 1e9))
    json.dump(dict(generator='tools/spice-reference/crosscheck.py --ac', ngspice=subprocess.run(
        ['ngspice', '-v'], capture_output=True, text=True).stdout.split('\n')[1].strip(' *'), cases=out, noise=noise),
        open(AC_FIXTURE, 'w'), indent=1)

# Devices at DC: a transistor between two sources, base-emitter and collector-emitter, one swept and the other held,
# and the currents the sources deliver into its base and collector; ngspice's .dc with every node, the device's internal
# ones too, shunted by 1 TΩ to ground as JSpice's are (gmin), so the sources' currents include the same shunts
DEVICE_SWEEPS = [
    dict(id='npn-vbe', note='test NPN card: currents against VBE at VCE 2 V (leakage, high injection, RB, RE)', kind='npn',
         params=GP_NPN, swept='vbe', fixed=2, start=0.45, stop=0.95, step=0.025),
    dict(id='npn-vce', note='test NPN card: currents against VCE at VBE 0.7 V, from reverse through saturation (BR, ISC, RC, VAF)',
         kind='npn', params=GP_NPN, swept='vce', fixed=0.7, start=-2, stop=10, step=0.25),
    dict(id='hot-npn-vbe', note='test NPN card at 70 °C: XTB, XTI and the leakage at temperature', kind='npn', params=GP_NPN,
         swept='vbe', fixed=2, start=0.4, stop=0.9, step=0.025, temperature=70),
    dict(id='pnp-vbe', note='test PNP card: currents against VBE at VCE -2 V', kind='pnp', params=GP_PNP, swept='vbe', fixed=-2,
         start=-0.45, stop=-0.95, step=-0.025),
    dict(id='pnp-vce', note='test PNP card: currents against VCE at VBE -0.7 V', kind='pnp', params=GP_PNP, swept='vce',
         fixed=-0.7, start=2, stop=-10, step=-0.25),
    dict(id='diode-forward', note='test diode card: current against forward voltage (N, RS, IKF)', kind='diode', params=TEST_DIODE,
         swept='vd', fixed=0, start=0.2, stop=1.6, step=0.05),
    dict(id='diode-reverse', note='test diode card: reverse current into its 80 V breakdown', kind='diode', params=TEST_DIODE,
         swept='vd', fixed=0, start=-82, stop=0, step=1),
    dict(id='hot-diode-forward', note='test diode card at 70 °C (EG, XTI)', kind='diode', params=TEST_DIODE, swept='vd', fixed=0,
         start=0.2, stop=1.4, step=0.05, temperature=70),
    dict(id='zener-reverse', note='test Zener card: into breakdown at 6.2 V and on (NBV, RS)', kind='zener', params=TEST_ZENER,
         swept='vd', fixed=0, start=-7.5, stop=0.9, step=0.1),
    dict(id='led-forward', note='a red LED with a series resistance: forward current (and its 5 V breakdown, reverse knee)',
         kind='led', params=TEST_LED, swept='vd', fixed=0, start=-6, stop=2.4, step=0.1),
    dict(id='default-npn-vce', note='an NPN at JSpice\'s defaults (Ebers-Moll, BR 1): currents against VCE at VBE 0.65 V',
         kind='npn', params={}, swept='vce', fixed=0.65, start=0, stop=10, step=0.25),
    dict(id='jfet-vgs', note='test JFET card: currents against VGS at VDS 5 V, from cut-off to the gate conducting (B, RS, IS)',
         kind='njfet', params=TEST_JFET, swept='vgs', fixed=5, start=-2.2, stop=0.8, step=0.05),
    dict(id='jfet-vds', note='test JFET card: currents against VDS at VGS -0.6 V, from inverse mode through the linear region '
         'into saturation (LAMBDA, RD)', kind='njfet', params=TEST_JFET, swept='vds', fixed=-0.6, start=-3, stop=12, step=0.25),
    dict(id='hot-jfet-vgs', note='test JFET card at 70 °C (TCV, BEX, XTI)', kind='njfet', params=TEST_JFET, swept='vgs', fixed=5,
         start=-2.2, stop=0.7, step=0.05, temperature=70),
    dict(id='pjfet-vgs', note='the test JFET card as P-channel: currents against VGS at VDS -5 V, from cut-off to the gate '
         'conducting', kind='pjfet', params=TEST_JFET, swept='vgs', fixed=-5, start=2.2, stop=-0.8, step=-0.05),
    dict(id='pjfet-vds', note='the test JFET card as P-channel: currents against VDS at VGS 0.6 V, from inverse mode into '
         'saturation', kind='pjfet', params=TEST_JFET, swept='vds', fixed=0.6, start=3, stop=-12, step=-0.25),
    dict(id='nmos-vgs', note='test NMOS card: currents against VGS at VDS 5 V, through the threshold (RS)', kind='nmos',
         params=TEST_NMOS, swept='vgs', fixed=5, start=0, stop=6, step=0.1),
    dict(id='nmos-vds', note='test NMOS card: currents against VDS at VGS 3.5 V, from the body diode and inverse mode (GAMMA) '
         'through the linear region into saturation (LAMBDA, RD)', kind='nmos', params=TEST_NMOS, swept='vds', fixed=3.5,
         start=-1.5, stop=10, step=0.25),
    dict(id='hot-nmos-vgs', note='test NMOS card at 70 °C (KP, the threshold and IS at temperature)', kind='nmos',
         params=TEST_NMOS, swept='vgs', fixed=5, start=0, stop=6, step=0.1, temperature=70),
    dict(id='pmos-vds', note='test PMOS card: currents against VDS at VGS -3 V, from its body diode through saturation',
         kind='pmos', params=TEST_PMOS, swept='vds', fixed=-3, start=1.5, stop=-10, step=-0.25),
    dict(id='default-nmos-vds', note='an NMOS at JSpice\'s defaults: currents against VDS at VGS 2.5 V, from its body diode '
         'conducting', kind='nmos', params={}, swept='vds', fixed=2.5, start=-0.6, stop=10, step=0.2),
    dict(id='default-jfet-vds', note='a JFET at JSpice\'s defaults: currents against VDS at VGS -0.5 V (inverse mode down to the '
         'gate-drain junction conducting)', kind='njfet', params={}, swept='vds', fixed=-0.5, start=-1.1, stop=10, step=0.1),
]

def run_ngspice_dc(sweep):
    part = dict(kind=sweep['kind'], name='Q1', params=sweep['params'], connections={})
    if sweep['kind'] in ('diode', 'zener', 'led'):
        # a diode across one source: the current into its anode
        data = tempfile.mktemp(suffix='.txt')
        deck = '\n'.join(['* JSpice device check',
                          '.options reltol=1e-9 abstol=1e-18 vntol=1e-12 gmin=1e-12 rshunt=1e12 itl1=500 itl2=500',
                          temperature_options(sweep.get('temperature', 27)),
                          'VD a 0 DC %.12g' % sweep['start'], 'D1 a 0 DT', '.model DT D(%s)' % diode_card(part, sweep['kind']),
                          '.control', 'dc VD %.12g %.12g %.12g' % (sweep['start'], sweep['stop'], sweep['step']),
                          'wrdata %s i(VD)' % data, 'quit', '.endc', '.end']) + '\n'
        with tempfile.NamedTemporaryFile('w', suffix='.cir', delete=False) as f:
            f.write(deck)
        result = subprocess.run(['ngspice', '-b', f.name], capture_output=True, text=True, timeout=600)
        if not os.path.exists(data):
            sys.exit('ngspice failed:\n' + deck + result.stdout[-3000:] + result.stderr[-3000:])
        rows = [list(map(float, line.split())) for line in open(data) if line.strip()]
        os.unlink(data)
        return [row[0] for row in rows], [-row[1] for row in rows], None
    temperature = sweep.get('temperature', 27)
    data = tempfile.mktemp(suffix='.txt')
    if sweep['kind'] in ('njfet', 'pjfet', 'nmos', 'pmos'):
        # a JFET or MOSFET between two sources, gate-source and drain-source: the currents into its gate and drain
        held = 'VDS' if sweep['swept'] == 'vgs' else 'VGS'
        jfet = 'NJF' if sweep['kind'] == 'njfet' else 'PJF'
        device = ['J1 d g 0 JT', '.model JT %s(%s)' % (jfet, jfet_card(part))] if sweep['kind'] in ('njfet', 'pjfet') else \
            ['M1 d g 0 0 MT L=1 W=1', '.model MT %s(%s)' % (sweep['kind'].upper(), mosfet_card(part, sweep['kind']))]
        deck = '\n'.join(['* JSpice device check',
                          '.options reltol=1e-9 abstol=1e-18 vntol=1e-12 gmin=1e-12 rshunt=1e12 itl1=500 itl2=500',
                          temperature_options(temperature),
                          'VGS g 0 DC %.12g' % (sweep['fixed'] if held == 'VGS' else sweep['start']),
                          'VDS d 0 DC %.12g' % (sweep['fixed'] if held == 'VDS' else sweep['start']),
                          ] + device + [
                          '.control', 'dc %s %.12g %.12g %.12g' % (sweep['swept'].upper(), sweep['start'], sweep['stop'], sweep['step']),
                          'wrdata %s i(VGS) i(VDS)' % data, 'quit', '.endc', '.end']) + '\n'
        with tempfile.NamedTemporaryFile('w', suffix='.cir', delete=False) as f:
            f.write(deck)
        result = subprocess.run(['ngspice', '-b', f.name], capture_output=True, text=True, timeout=600)
        if not os.path.exists(data):
            sys.exit('ngspice failed:\n' + deck + result.stdout[-3000:] + result.stderr[-3000:])
        rows = [list(map(float, line.split())) for line in open(data) if line.strip()]
        os.unlink(data)
        return [row[0] for row in rows], [-row[1] for row in rows], [-row[3] for row in rows]
    held = 'VCE' if sweep['swept'] == 'vbe' else 'VBE'
    deck = '\n'.join(['* JSpice device check',
                      '.options reltol=1e-9 abstol=1e-18 vntol=1e-12 gmin=1e-12 rshunt=1e12 itl1=500 itl2=500',
                      temperature_options(temperature),
                      'VBE b 0 DC %.12g' % (sweep['fixed'] if held == 'VBE' else sweep['start']),
                      'VCE c 0 DC %.12g' % (sweep['fixed'] if held == 'VCE' else sweep['start']),
                      'Q1 c b 0 QT', '.model QT %s(%s)' % (sweep['kind'].upper(), bipolar_card(part)),
                      '.control', 'dc %s %.12g %.12g %.12g' % (sweep['swept'].upper(), sweep['start'], sweep['stop'], sweep['step']),
                      'wrdata %s i(VBE) i(VCE)' % data, 'quit', '.endc', '.end']) + '\n'
    with tempfile.NamedTemporaryFile('w', suffix='.cir', delete=False) as f:
        f.write(deck)
    result = subprocess.run(['ngspice', '-b', f.name], capture_output=True, text=True, timeout=600)
    if not os.path.exists(data):
        sys.exit('ngspice failed:\n' + deck + result.stdout[-3000:] + result.stderr[-3000:])
    rows = [list(map(float, line.split())) for line in open(data) if line.strip()]
    os.unlink(data)
    # a source's current runs into its + terminal: the transistor's is the opposite
    return [row[0] for row in rows], [-row[1] for row in rows], [-row[3] for row in rows]

def devices_main():
    out = []
    for sweep in DEVICE_SWEEPS:
        voltages, base, collector = run_ngspice_dc(sweep)
        entry = dict(id=sweep['id'], note=sweep['note'], kind=sweep['kind'], params=sweep['params'], swept=sweep['swept'],
                     fixed=sweep['fixed'], voltages=[round(v, 9) for v in voltages])
        if collector is None:
            entry['anode'] = [float('%.12g' % i) for i in base]
        elif sweep['kind'] in ('njfet', 'pjfet', 'nmos', 'pmos'):
            entry.update(gate=[float('%.12g' % i) for i in base], drain=[float('%.12g' % i) for i in collector])
        else:
            entry.update(base=[float('%.12g' % i) for i in base], collector=[float('%.12g' % i) for i in collector])
        if 'temperature' in sweep:
            entry['temperature'] = sweep['temperature']
        out.append(entry)
        currents = collector if collector is not None else base
        print('%-18s %.4g..%.4g A' % (sweep['id'], min(currents), max(currents)))
    json.dump(dict(generator='tools/spice-reference/crosscheck.py --devices', ngspice=subprocess.run(
        ['ngspice', '-v'], capture_output=True, text=True).stdout.split('\n')[1].strip(' *'), sweeps=out),
        open(DEVICE_FIXTURE, 'w'), indent=1)

# MARK: - Netlists as written

# Decks ngspice runs as they are and JSpice imports (SpiceNetlist) and runs: E, F, G, H and B sources in every form (gain,
# POLY, VALUE, TABLE, V= and I=, .param constants), and a subcircuit of them (an op-amp macromodel after Boyle's, with
# test values, not any maker's) whose F and H read a source inside it
NETLIST_CASES = [
    dict(id='controlled-sources', note='E, F, G, H (gain and POLY), B (V= and I=), TABLE and VALUE, driven by a 1 kHz sine',
         duration=2e-3, probes=['e1', 'g1', 'f1', 'h1', 'p2', 'b1', 'b2', 't3', 'v4'], netlist='''controlled sources
.param gain=3 rload=2k
VIN in 0 SIN(0 1 1k)
R1 in a 1k
VSENSE a b DC 0
R2 b 0 1k
E1 e1 0 in 0 {gain}
RE1 e1 0 10k
G1 0 g1 in 0 1m
RG1 g1 0 {rload}
F1 0 f1 VSENSE 2
RF1 f1 0 1k
H1 h1 0 VSENSE 500
RH1 h1 0 10k
E2 p2 0 POLY(2) (in,0) (e1,0) 0.1 0.5 0.2 0.05 0.01 0.02
RP2 p2 0 10k
B1 b1 0 V=2*tanh(V(in)*1.5) + 0.1*V(e1,in)
RB1 b1 0 10k
B2 0 b2 I=1m*V(in)^2 + 0.5m*I(VSENSE)*1k
RB2 b2 0 1k
E3 t3 0 TABLE {V(in)} = (-1,-0.5) (0,0) (0.5,1) (1,1.2)
RT3 t3 0 10k
EV v4 0 VALUE={V(in)*V(in) - 0.3*abs(V(in)) + max(min(V(e1), 2), -2)}
RV4 v4 0 10k
'''),
    dict(id='opamp-macromodel', note='an inverting amplifier (gain 4.7) with a Boyle-style op-amp macromodel: an NPN pair, G and '
         'POLY G stages with Miller compensation, H and F reading the output current, a B source limiting the swing',
         duration=2e-3, probes=['out', 'inv'], netlist='''op-amp macromodel
.subckt OPX inp inn vcc vee out
Q1 c1 inn e1 QIN
Q2 c2 inp e2 QIN
RC1 vcc c1 5.3k
RC2 vcc c2 5.3k
RE1 e1 e 2k
RE2 e2 e 2k
IEE e vee 20u
GA n6 0 c1 c2 1.9e-4
R2 n6 0 100k
CC n6 n7 30p
GB n7 0 POLY(2) (n6,0) (vcc,vee) 0 2.4 0 0.001
RO2 n7 0 50
VSENSE n7 n8 DC 0
HLIM n9 0 VSENSE 1
EOUT n10 0 VALUE={V(n8) - 0.05*tanh(V(n9)/0.02)}
BOUT out 0 V=max(min(V(n10), V(vcc)-1.5), V(vee)+1.5)
FCLAMP 0 n6 VSENSE 0.01
.model QIN NPN(IS=8e-16 BF=120 VAF=80)
.ends
VCC vcc 0 DC 12
VEE vee 0 DC -12
VIN in 0 SIN(0 0.5 2k)
R1 in inv 10k
R2 inv out 47k
RL out 0 2k
X1 0 inv vcc vee out OPX
'''),
    dict(id='jfet-opamp-library', note='two JFET-input op-amps from a library file (.lib with sections, a .include within it), '
         'one given PARAMS:, a .func limiting the output, P-JFETs, a diode and a transistor with area factors',
         duration=3e-3, probes=['out', 'out2', 'dk', 'e3'], files={
             'opamps.lib': """* a test library (not a vendor's): sections, a subcircuit with parameters
.lib other
.subckt JOPA a b
R1 a b 1
.ends
.endl
.lib jfet
.include parts.mod
.subckt JOPA inp inn vcc vee out PARAMS: GM=1.9e-4 RO=50
.param KB={120/RO}
.func clip(x, lo, hi) {max(min(x, hi), lo)}
ISS vcc 10 DC 200u
J1 11 inn 10 JX 2
J2 12 inp 10 JX 2
RD1 11 vee 3k
RD2 12 vee 3k
GA n6 0 11 12 {GM}
R2 n6 0 100k
CC n6 n7 30p
GB n7 0 n6 0 {KB}
RO2 n7 0 {RO}
BOUT out 0 V=clip(V(n7), V(vee)+1.5, V(vcc)-1.5)
.model JX PJF(IS=15e-12 BETA=135e-6 VTO=-1 LAMBDA=0.01 CGS=3p CGD=1p RD=10 RS=10)
.ends
.endl
""",
             'parts.mod': """* models for the test library
.model QB NPN(IS=2e-15 BF=150 VAF=90 RB=50 RE=0.5 CJE=5p CJC=3p)
.model DCLAMP D(IS=1e-14 RS=5 CJO=2p N=1.2)
"""}, netlist="""JFET-input op-amps from a library
.lib opamps.lib jfet
.param rf=22k
VCC vcc 0 DC 15
VEE vee 0 DC -15
VIN in 0 SIN(0 0.4 1k)
R1 in inv 10k
R2 inv out {rf}
RL out 0 2k
X1 0 inv vcc vee out JOPA PARAMS: GM=3e-4
R3 out f1 4.7k
C3 f1 0 4.7n
X2 f1 out2 vcc vee out2 JOPA
RL2 out2 0 10k
D1 out2 dk DCLAMP area=4
R4 dk 0 3.3k
Q1 vcc out2 e3 QB 3
RE3 e3 vee 4.7k
"""),
]

def netlists_main():
    out = []
    for case in NETLIST_CASES:
        # the deck and the files it includes, side by side
        folder = tempfile.mkdtemp()
        for name, text in case.get('files', {}).items():
            with open(os.path.join(folder, name), 'w') as f:
                f.write(text)
        data = os.path.join(folder, 'data.txt')
        step = case['duration'] / 500
        deck = case['netlist'] + '\n'.join([
            '.options reltol=1e-6 abstol=1e-13 vntol=1e-8 gmin=1e-12 method=gear maxord=2 itl4=200',
            '.tran %.6g %.12g 0 %.6g uic' % (step, case['duration'], step), '.control', 'run',
            'wrdata %s %s' % (data, ' '.join('v(%s)' % p for p in case['probes'])), 'quit', '.endc', '.end']) + '\n'
        with open(os.path.join(folder, 'deck.cir'), 'w') as f:
            f.write(deck)
        result = subprocess.run(['ngspice', '-b', 'deck.cir'], capture_output=True, text=True, timeout=600, cwd=folder)
        if not os.path.exists(data):
            sys.exit('ngspice failed:\n' + deck + result.stdout[-3000:] + result.stderr[-3000:])
        rows = [list(map(float, line.split())) for line in open(data) if line.strip()]
        os.unlink(data)
        time = [row[0] for row in rows]
        entry = dict(id=case['id'], note=case['note'], netlist=case['netlist'], duration=case['duration'],
                     times=[float('%.9g' % t) for t in time], probes=[])
        if 'files' in case:
            entry['files'] = case['files']
        for k, probe in enumerate(case['probes']):
            values = [row[2 * k + 1] for row in rows]
            entry['probes'].append(dict(net=probe, values=[float('%.7g' % v) for v in values]))
            print('%-18s %-6s %.4g..%.4g V' % (case['id'], probe, min(values), max(values)))
        out.append(entry)
    json.dump(dict(generator='tools/spice-reference/crosscheck.py --netlists', ngspice=subprocess.run(
        ['ngspice', '-v'], capture_output=True, text=True).stdout.split('\n')[1].strip(' *'), cases=out),
        open(NETLIST_FIXTURE, 'w'), indent=1)

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
    if '--ac' in sys.argv:
        ac_main()
    elif '--devices' in sys.argv:
        devices_main()
    elif '--netlists' in sys.argv:
        netlists_main()
    else:
        main()
