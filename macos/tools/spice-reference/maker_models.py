#!/usr/bin/env python3
"""ngspice's figures for the makers' op-amp models of MakerModelCatalog, measured as MakerModels.measureOpAmp measures
them: each model downloaded from its maker, checked against the SHA-256 the catalog names, run in ngspice, and its
figures printed as the catalog's `ngspice:` dictionaries (MakerModelCatalogTests requires JSpice to match them).

ngspice reads PSpice's files with these spelled its way: VSWITCH as a B source with PSpice's resistance (as
SpiceNetlist.switchResistance writes it), LIMIT and IF as min/max and ?:, | and & as || and &&, TEMP as temper, a
resistor's model name dropped (R_NOISELESS), node names ending in + or - renamed.

    python3 maker_models.py            # every model in MODELS
    python3 maker_models.py OPA1678    # one
"""
import cmath, hashlib, io, math, os, re, subprocess, sys, tempfile, urllib.request, zipfile


def split_args(text):
    depth, args, cur = 0, [], ''
    for ch in text:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            args.append(cur)
            cur = ''
        else:
            cur += ch
    args.append(cur)
    return args


def replace_calls(text, name, make):
    while True:
        m = re.search(r'\b' + name + r'\s*\(', text, re.I)
        if not m:
            return text
        start = m.end()
        depth, k = 1, start
        while depth:
            if text[k] == '(':
                depth += 1
            elif text[k] == ')':
                depth -= 1
            k += 1
        args = split_args(text[start:k - 1])
        text = text[:m.start()] + make(args) + text[k:]


def switch_resistance(control, on, off, ron, roff):
    lm, lr = math.log(math.sqrt(ron * roff)), math.log(ron / roff)
    x = '((max(min(%s,%.17g),%.17g)-(%.17g))/(%.17g))' % (control, max(on, off), min(on, off), (on + off) / 2, on - off)
    return 'exp(%.17g+(%.17g)*(1.5*%s-2*%s*%s*%s))' % (lm, lr, x, x, x, x)


def value(text):
    t = text.strip().lower()
    m = re.match(r'^([-+]?[0-9.]+(?:e[-+]?\d+)?)(meg|mil|t|g|k|m|u|n|p|f)?', t)
    scale = {'meg': 1e6, 't': 1e12, 'g': 1e9, 'k': 1e3, 'm': 1e-3, 'u': 1e-6, 'n': 1e-9, 'p': 1e-12, 'f': 1e-15, None: 1}
    return float(m.group(1)) * scale[m.group(2)]


def translate(text):
    lines = []
    for raw in text.replace('\r', '').replace('\x1a', '').split('\n'):
        # a + line continues the last line that is not blank or a comment, as PSpice reads it (TINA's files leave blank
        # lines between a subcircuit's PARAMS: lines)
        last = next((k for k in range(len(lines) - 1, -1, -1) if lines[k].strip() and not lines[k].startswith('*')), None)
        if raw.startswith('+') and last is not None:
            lines[last] += ' ' + raw[1:]
        else:
            lines.append(raw)
    out, models = [], {}
    # each subcircuit's switch models
    scope = None
    for line in lines:
        words = line.split()
        if not words or line.startswith('*'):
            continue
        first = words[0].lower()
        if first == '.subckt':
            scope = words[1].lower()
        elif first == '.ends':
            scope = None
        elif first == '.model' and 'vswitch' in line.lower():
            params = dict((k.upper(), value(v)) for k, v in re.findall(r'(\w+)\s*=\s*([-+0-9.eE]+\w*)', line))
            models[(scope, words[1].lower())] = params
    scope = None
    for line in lines:
        words = line.split()
        if not words or line.startswith('*'):
            continue
        first = words[0].lower()
        # node names ending in + or -
        line = re.sub(r'\b([A-Za-z_][A-Za-z0-9_]*)([+-])(?=[\s,)]|$)', lambda m: m.group(1) + ('_P' if m.group(2) == '+' else '_N'), line)
        words = line.split()
        if first == '.subckt':
            scope = words[1].lower()
        elif first == '.ends':
            scope = None
        if first == '.model' and ('vswitch' in line.lower() or ' res' in line.lower()):
            continue
        if first.startswith('.model'):
            line = re.sub(r'KF=\{[^}]*\}', '', line, flags=re.I)
        if first.startswith('r') and len(words) == 5:
            line = ' '.join(words[:3] + [words[4]])
        if first.startswith('s'):
            p = models.get((scope, words[5].lower())) or models[(None, words[5].lower())]
            r = switch_resistance('V(%s,%s)' % (words[3], words[4]), p.get('VON', 1), p.get('VOFF', 0), p.get('RON', 1), p.get('ROFF', 1e6))
            line = 'B%s %s %s I=V(%s,%s)/%s' % (words[0], words[1], words[2], words[1], words[2], r)
        if first.startswith('x') and line.rstrip().lower().endswith('params:'):
            line = line.rstrip()[:-len('params:')]
        if '{' in line:
            head, body = line[:line.index('{')], line[line.index('{'):]
            body = replace_calls(body, 'LIMIT', lambda a: '(min(max(%s,%s),%s))' % (a[0], a[1], a[2]))
            body = replace_calls(body, 'IF', lambda a: '((%s) ? (%s) : (%s))' % (a[0], a[1], a[2]))
            body = re.sub(r'(?<![|])\|(?![|])', '||', body)
            body = re.sub(r'(?<![&])&(?![&])', '&&', body)
            body = re.sub(r'\bTEMP\b', 'temper', body, flags=re.I)
            line = head + body
        out.append(line)
    return '\n'.join(out) + '\n'


def run(deck, folder):
    path = os.path.join(folder, 'deck.cir')
    open(path, 'w').write(deck)
    r = subprocess.run(['ngspice', '-b', 'deck.cir'], capture_output=True, text=True, timeout=900, cwd=folder)
    return r.stdout + r.stderr


def measure(model, subckt, pins, supply=15.0, load=10e3, slew_gain=1, order=None):
    folder = tempfile.mkdtemp()
    open(os.path.join(folder, 'model.lib'), 'w').write(translate(model))
    p, n = '_P', '_N'
    rename = lambda names: [re.sub(r'([+-])$', lambda m: p if m.group(1) == '+' else n, x) for x in names]
    # the subcircuit's pins in its own order, and as +in, -in, V+, V-, out
    pins = rename(pins)
    roles = rename(order) if order else pins
    opts = '.options reltol=1e-6 abstol=1e-13 vntol=1e-9 gmin=1e-12 itl1=1000 itl4=200\n'

    def bench(inp, follower, extra=''):
        nodes = {roles[0]: 'inp', roles[1]: 'out' if follower else 'inn', roles[2]: 'vcc', roles[3]: 'vee', roles[4]: 'out'}
        x = 'XU1 ' + ' '.join(nodes[q] for q in pins) + ' ' + subckt
        return ('bench\n.include model.lib\n%s\nVP vcc 0 DC %g\nVN 0 vee DC %g\nRL out 0 %g\n%s\n%s%s%s' %
                (x, supply, supply, load, inp, '' if follower else 'VM inn 0 DC 0\n', opts, extra))

    # a follower at rest: offset and supply current
    out = run(bench('VI inp 0 DC 0', True) + '.control\nop\nprint v(out) i(VP)\nquit\n.endc\n.end\n', folder)
    offset = float(re.search(r'v\(out\) = ([-+0-9.e]+)', out).group(1))
    iq = -float(re.search(r'i\(vp\) = ([-+0-9.e]+)', out, re.I).group(1))
    # an inverting stage of gain -1, the + input grounded: the open-loop gain is the output over the - input
    data = os.path.join(folder, 'ac.txt')
    nodes = {roles[0]: '0', roles[1]: 'inn', roles[2]: 'vcc', roles[3]: 'vee', roles[4]: 'out'}
    deck = ('inverting\n.include model.lib\nXU1 %s %s\nVP vcc 0 DC %g\nVN 0 vee DC %g\nRL out 0 %g\nVI in 0 DC 0 AC 1\n'
            'R1 in inn 10k\nR2 inn out 10k\n%s.control\nset wr_singlescale\nop\nac dec 10 0.1 1e9\nwrdata %s v(out) v(inn)\n'
            'quit\n.endc\n.end\n') % (' '.join(nodes[q] for q in pins), subckt, supply, supply, load, opts, data)
    run(deck, folder)
    rows = [list(map(float, l.split())) for l in open(data) if l.strip()]
    f = [r[0] for r in rows]
    A = [-complex(r[1], r[2]) / complex(r[3], r[4]) for r in rows]
    gain = 20 * math.log10(abs(A[0]))
    gbw = None
    for k in range(1, len(A)):
        if abs(A[k - 1]) >= 100 > abs(A[k]):
            a, b = math.log(abs(A[k - 1]) / 100), math.log(abs(A[k]) / 100)
            t = a / (a - b)
            gbw = 100 * math.exp(math.log(f[k - 1]) + t * (math.log(f[k]) - math.log(f[k - 1])))
            break
    ugf = pm = None
    for k in range(1, len(A)):
        if abs(A[k - 1]) >= 1 > abs(A[k]):
            a, b = math.log(abs(A[k - 1])), math.log(abs(A[k]))
            t = a / (a - b)
            ugf = math.exp(math.log(f[k - 1]) + t * (math.log(f[k]) - math.log(f[k - 1])))
            pa, pb = cmath.phase(A[k - 1]), cmath.phase(A[k])
            if pb - pa > math.pi: pb -= 2 * math.pi
            elif pa - pb > math.pi: pb += 2 * math.pi
            pm = 180 + math.degrees(pa + t * (pb - pa))
            break
    # slew: 10 V steps at 10 kHz, into a follower or the inverting stage as the datasheet measures (slew_gain +1 or -1)
    data = os.path.join(folder, 'tr.txt')
    period = 1e-4
    pulse = 'PULSE(5 -5 %g 1n 1n %g %g)' % (period / 2, period / 2 - 1e-9, period)
    # (with Gear's rule where ngspice gives up with the trapezoidal one: the run must reach its end)
    for method in ('', ' method=gear'):
        control = ('.options reltol=1e-3 abstol=1e-12 vntol=1e-6%s\n.tran %g %g 0 %g\n.control\nrun\nwrdata %s v(%s) v(out)\n'
                   'quit\n.endc\n.end\n' % (method, period / 20000, 2.5 * period, period / 2000, data, 'inp' if slew_gain > 0 else 'in'))
        open(data, 'w').close()
        if slew_gain > 0:
            run(bench('VI inp 0 %s' % pulse, True) + control, folder)
        else:
            run(('inverting\n.include model.lib\nXU1 %s %s\nVP vcc 0 DC %g\nVN 0 vee DC %g\nRL out 0 %g\nVI in 0 %s\n'
                 'R1 in inn 10k\nR2 inn out 10k\n%s') % (' '.join(nodes[q] for q in pins), subckt, supply, supply, load, pulse, opts)
                + control, folder)
        rows = [list(map(float, l.split())) for l in open(data) if l.strip()]
        if rows and rows[-1][0] > 2.5 * period * 0.999:
            break
    else:
        rows = None
        print('// ngspice gives up stepping the slew test ("timestep too small"): no slew rate', file=sys.stderr)
    t = [r[0] for r in rows or []]; vin = [r[1] for r in rows or []]; vout = [r[3] for r in rows or []]

    def crossing(values, level, rising, after):
        for k in range(1, len(values)):
            if t[k] > after and ((values[k - 1] < level <= values[k]) if rising else (values[k - 1] > level >= values[k])):
                return t[k - 1] + (level - values[k - 1]) / (values[k] - values[k - 1]) * (t[k] - t[k - 1])
    # the output's 90 % crossing after the input's edge, and its last 10 % crossing before that (the output can jump at
    # the step's instant, through the inputs' clamp diodes or its input stage, and fall back before it slews)
    def last_crossing(values, level, rising, after, before):
        last = None
        for k in range(1, len(values)):
            if t[k] > after and t[k - 1] < before and ((values[k - 1] < level <= values[k]) if rising else (values[k - 1] > level >= values[k])):
                last = t[k - 1] + (level - values[k - 1]) / (values[k] - values[k - 1]) * (t[k] - t[k - 1])
        return last
    slew = [None, None]
    for k, rising in enumerate((True, False)) if rows else ():
        e = crossing(vin, 0, rising if slew_gain > 0 else not rising, period)
        b = crossing(vout, 4 if rising else -4, rising, e - period / 100)
        a = last_crossing(vout, -4 if rising else 4, rising, e - period / 100, b)
        slew[k] = 8 / (b - a) / 1e6
    # swing, open loop
    swing = []
    for v in (0.1, -0.1):
        # in time, as a DC solution of a saturated output can take ngspice long: the input ramped to it, then held
        data = os.path.join(folder, 'sw.txt')
        # (where ngspice gives up with its trapezoidal rule, "timestep too small" as a maker's model's overload
        # comparator chatters, it may run to the end with Gear's, or from an operating point with the input already
        # there; the run must reach its end)
        for source, method in (('PWL(0 0 1m %g)', ''), ('PWL(0 0 1m %g)', ' method=gear'), ('DC %g', ''),
                               ('DC %g', ' method=gear')):
            open(data, 'w').close()
            run(bench('VI inp 0 ' + source % v, False) + '.options reltol=1e-3 abstol=1e-12 vntol=1e-6%s\n'
                '.tran 1u 5m 0 10u\n.control\nrun\nwrdata %s v(out)\nquit\n.endc\n.end\n' % (method, data), folder)
            rows = [list(map(float, l.split())) for l in open(data) if l.strip()]
            if rows and rows[-1][0] > 5e-3 * 0.999:
                break
        else:
            raise RuntimeError('ngspice could not run the open-loop swing to %g V' % v)
        swing.append(rows[-1][1])
    return dict(offset_mv=offset * 1e3, iq_ma=iq * 1e3, aol_db=gain, gbw_mhz=(gbw or 0) / 1e6, ugf_mhz=(ugf or 0) / 1e6, pm_deg=pm,
                slew_rise=slew[0], slew_fall=slew[1], swing_high=swing[0], swing_low=swing[1])



# MakerModelCatalog.models: part, archive, file, SHA-256, subcircuit, supplies, load and the slew rate's gain, and the
# subcircuit's pins for +in, -in, V+, V- and out where its own order is not that
MODELS = [
    ('TL072', 'https://www.ti.com/lit/zip/SLOJ067', 'TL072.301',
     '74e89d558163615ac7a19f0c783101a6f8af77fb6d80bd3c20c6ab66426561cd', 'TL072', 15, 10e3, 1),
    ('OPA1678', 'https://www.ti.com/lit/zip/SBOMAC3', 'OPA167x.LIB',
     'a4a2f63b714c799bd4ccbf52fa71922d2786f93fcdfcc10f0b11377194beef77', 'OPA167x', 15, 2e3, -1),
    ('OPA2134', 'https://www.ti.com/lit/zip/SBOM042', 'OPAx134.LIB',
     '8ff414c678a7f8330b87504d7e0553de20ca87bdc713cecf81ab3448b4d7608f', 'OPAx134', 15, 2e3, 1),
    ('OPA1612', 'https://www.ti.com/lit/zip/SBOM396', 'OPA161x.LIB',
     'c86df5d4b2d26ec196c0a6158a61004a6747aec5440fcc2031674ad62a448ef7', 'OPA161x', 15, 2e3, -1),
    ('RC4558', 'https://www.ti.com/lit/zip/SLOJ053', 'RC4558.301',
     '6ff2f51ab04648973e87a854fc0a1ad0dc8ada7c9c3dcc6869c2ab64030246f6', 'RC4558', 15, 2e3, 1),
    ('UA741', 'https://www.ti.com/lit/zip/SLOJ138', 'UA741.301',
     '6fc707dc0f43edccf82c22ca3cf582f8fa3e65b3ceb8e73fc6caf6d8679b6f17', 'UA741', 15, 2e3, 1),
    ('TL074', 'https://www.ti.com/lit/zip/SLOJ068', 'TL074.301',
     'a5f384a32ed660490d7ad57b82ddad836dfcf3b462d9dd8987e8fd4de603b1f3', 'TL074', 15, 10e3, 1),
    ('LM358', 'https://www.ti.com/lit/zip/SNOM268', 'lmx58_lm2904.lib',
     '467a3e573420d1f5a21fab57b76be0e13073e854f609a73459a191958e314726', 'LMX58_LM2904', 15, 2e3, 1),
    ('OPA1656', 'https://www.ti.com/lit/zip/SBOMAW6', 'OPA1656.LIB',
     '9847ed60c62e792ee6f1c84899278a3c11ce71a6d21804bdd88f51199f1ba055', 'OPA1656', 15, 2e3, -1),
    ('OPA1642', 'https://www.ti.com/lit/zip/SBOM407', 'OPA164x.LIB',
     'c3504c5bb927bd66e411e71a3b92e564cf4a6468d94cd6032724ec008938a16c', 'OPA164x', 15, 2e3, 1),
]

# the catalog's names for the figures, and their datasheet units
SWIFT = [('offset', 'offset_mv'), ('supplyCurrent', 'iq_ma'), ('openLoopGain', 'aol_db'), ('gainBandwidth', 'gbw_mhz'),
         ('unityGain', 'ugf_mhz'), ('phaseMargin', 'pm_deg'), ('slewRise', 'slew_rise'), ('slewFall', 'slew_fall'),
         ('swingHigh', 'swing_high'), ('swingLow', 'swing_low')]


def download(archive, name, sha):
    request = urllib.request.Request(archive, headers={'User-Agent': 'Mozilla/5.0 (Macintosh) JSpice (fetching a maker\'s SPICE model)'})
    data = urllib.request.urlopen(request, timeout=120).read()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        member = next(n for n in z.namelist() if os.path.basename(n).lower() == name.lower())
        file = z.read(member)
    found = hashlib.sha256(file).hexdigest()
    if found != sha:
        sys.exit('%s from %s is not the revision the catalog names: its SHA-256 is %s' % (name, archive, found))
    return file.decode('latin-1')


if __name__ == '__main__':
    wanted = [a.lower() for a in sys.argv[1:]]
    for part, archive, name, sha, subckt, supply, load, slew_gain, *order in MODELS:
        if wanted and part.lower() not in wanted:
            continue
        text = download(archive, name, sha)
        m = re.search(r'^\.SUBCKT\s+' + re.escape(subckt) + r'\s+(.*)$', text, re.I | re.M)
        figures = measure(text, subckt, m.group(1).split()[:5], supply, load, slew_gain, order[0] if order else None)
        print('// %s' % part)
        print('ngspice: [' + ', '.join('.%s: %.6g' % (key, figures[k]) for key, k in SWIFT if figures.get(k) is not None) + '],')
