#!/usr/bin/env python3
"""Random design rules for boards, for checking the port's rules engine (KiCadRouter's DesignRules, its expression
language and its rules engine, and the DRC, zone filler and router that go by them) against KiCad's: a rules file of
random rules written beside each board (NAME.kicad_dru, where KiCad's DRC engine finds them; drc.py and fills.py then
run KiCad on the board with them). Each rule has a random condition made of what the board has (its nets, net
classes, layers, footprints' references and library links, pads' numbers, its named rule areas for intersectsArea
and enclosedByArea), of every kind the language has: properties of A and B (net class, net name with wildcards,
type, pad type and shape, via type, layer, width, sizes, reference...), the functions (existsOnLayer, isPlated,
intersectsCourtyard and its front and back ones, intersectsArea, memberOfFootprint, hasNetclass, inDiffPair,
isCoupledDiffPair, getField...), L, comparisons with units, arithmetic, !, && and ||; and one or two constraints:
clearances (copper, hole, edge), track widths, via diameters, hole sizes, annular widths, hole to hole, disallows,
assertions (an assertion of a random test, so each item's evaluation by KiCad is in its report), now and then a rule
layer and a severity; a few files with a rule KiCad cannot read or compile (a syntax error, an unknown property or
function, a number without units), whose quirks the port follows. Some boards get none, so a folder has boards
with and without rules. With --fills, the filler's constraints too (physical clearances, thermal relief gaps and
spoke widths, zone connections), which the port's DRC does not check (a board with them is one its DRC skips).

    rules.py [--fills] [--all] BOARD.kicad_pcb...  [--seed SEED]

Each board's rules come from a random sequence of its own (its name and the seed), so that the same board gives the
same file; --all writes rules for every board (else for about two of three).
"""

import json
import os
import random
import re
import sys


def board_facts(path):
    """What a board has for the rules to name: its nets, net classes, copper layers, footprints, pads, named areas"""
    with open(path) as f:
        text = f.read()
    facts = {}
    facts["nets"] = sorted(set(re.findall(r'\(net "([^"]+)"\)', text)) - {""})
    facts["copper"] = [n for n in re.findall(r'\(\d+ "([^"]+\.Cu)" (?:signal|power|mixed|jumper)', text)]
    facts["refs"] = sorted(set(re.findall(r'\(property "Reference" "([^"]+)"', text)))
    facts["libs"] = sorted(set(re.findall(r'\(footprint "([^"]+)"', text)))
    facts["pads"] = sorted(set(re.findall(r'\(pad "([^"]*)"', text)) - {""})
    facts["areas"] = sorted(set(re.findall(r'\(name "([^"]+)"\)', text)))
    pro = os.path.splitext(path)[0] + ".kicad_pro"
    classes = ["Default"]
    try:
        with open(pro) as f:
            classes = [c["name"] for c in json.load(f)["net_settings"]["classes"]]
    except (OSError, KeyError, ValueError):
        pass
    facts["classes"] = classes
    return facts


def mm(v):
    return f"{v:.3f}".rstrip("0").rstrip(".") + "mm"


def length(rng, lo, hi):
    """A length between lo and hi millimetres, now and then in mils or inches"""
    v = round(rng.uniform(lo, hi), 2)
    r = rng.random()
    if r < 0.15:
        return f"{round(v / 0.0254, 1)}mil"
    if r < 0.2:
        return f"{round(v / 25.4, 4)}in"
    return mm(v)


def quote(s):
    return "'" + s.replace("'", "\\'") + "'"


class Conditions:
    """Random conditions on a board's items"""

    def __init__(self, rng, facts):
        self.rng = rng
        self.f = facts

    def pick(self, xs, fallback):
        return self.rng.choice(xs) if xs else fallback

    def wildcard(self, s):
        """A name, or a wildcard matching it (and maybe others)"""
        rng = self.rng
        r = rng.random()
        if r < 0.6 or len(s) < 2:
            return s
        if r < 0.8:
            return s[: rng.randint(1, len(s) - 1)] + "*"
        k = rng.randrange(len(s))
        return s[:k] + "?" + s[k + 1:]

    def atom(self, who):
        rng = self.rng
        f = self.f
        kind = rng.choice(["netclass", "netclass", "net", "net", "type", "type", "padtype", "padshape", "viatype",
                           "layer", "width", "size", "hole", "ref", "lib", "padnum", "plated", "exists",
                           "courtyard", "area", "area", "member", "hasnetclass", "diffpair", "coupled", "L",
                           "locked", "field", "fpref", "arith", "sheet"])
        x = who
        eq = rng.choice(["==", "==", "==", "!="])
        if kind == "netclass":
            return f"{x}.NetClass {eq} {quote(self.wildcard(self.pick(f['classes'], 'Default')))}"
        if kind == "net":
            return f"{x}.NetName {eq} {quote(self.wildcard(self.pick(f['nets'], 'GND')))}"
        if kind == "type":
            t = rng.choice(["Pad", "Via", "Track", "Zone", "Graphic", "Footprint", "Text", "Arc", "pad", "via", "track"])
            return f"{x}.Type {eq} {quote(t)}"
        if kind == "padtype":
            t = rng.choice(["SMD", "Through-hole", "NPTH, mechanical", "Edge connector", "Through*"])
            return f"{x}.Pad_Type {eq} {quote(t)}"
        if kind == "padshape":
            t = rng.choice(["Circle", "Rectangle", "Oval", "Trapezoid", "Rounded rectangle", "Chamfered rectangle",
                            "Custom", "R*"])
            return f"{x}.Pad_Shape {eq} {quote(t)}"
        if kind == "viatype":
            t = rng.choice(["Through", "Blind", "Buried", "Micro", "Blind/buried"])
            return f"{x}.Via_Type {eq} {quote(t)}"
        if kind == "layer":
            l = self.pick(f["copper"], "F.Cu")
            if rng.random() < 0.2:
                l = rng.choice(["F.SilkS", "F.Silkscreen", "B.Courtyard", "*.Cu", "In*.Cu", "F.*"])
            return f"{x}.Layer {eq} {quote(l)}"
        if kind == "width":
            op = rng.choice(["<", ">", "<=", ">=", "=="])
            return f"{x}.Width {op} {length(rng, 0.1, 0.4)}"
        if kind == "size":
            op = rng.choice(["<", ">", "<=", ">="])
            return f"{x}.{rng.choice(['Size_X', 'Size_Y'])} {op} {length(rng, 0.3, 2.5)}"
        if kind == "hole":
            op = rng.choice(["<", ">", ">="])
            prop = rng.choice(["Hole_Size_X", "Hole_Size_Y", "Hole", "Diameter"])
            return f"{x}.{prop} {op} {length(rng, 0.2, 1.5)}"
        if kind == "ref":
            return f"{x}.Reference {eq} {quote(self.wildcard(self.pick(f['refs'], 'U1')))}"
        if kind == "lib":
            return f"{x}.Library_Link {eq} {quote(self.wildcard(self.pick(f['libs'], 'R_0603')))}"
        if kind == "padnum":
            return f"{x}.Pad_Number {eq} {quote(self.pick(f['pads'], '1'))}"
        if kind == "plated":
            return ("!" if rng.random() < 0.3 else "") + f"{x}.isPlated()"
        if kind == "exists":
            return f"{x}.existsOnLayer({quote(self.pick(f['copper'], 'F.Cu'))})"
        if kind == "courtyard":
            fn = rng.choice(["intersectsCourtyard", "intersectsFrontCourtyard", "intersectsBackCourtyard",
                             "insideCourtyard"])
            arg = self.pick(f["refs"], "U1")
            if rng.random() < 0.2:
                arg = arg[:1] + "*"
            return f"{x}.{fn}({quote(arg)})"
        if kind == "area":
            fn = rng.choice(["intersectsArea", "intersectsArea", "enclosedByArea", "insideArea"])
            return f"{x}.{fn}({quote(self.pick(f['areas'], 'Keepout 1'))})"
        if kind == "member":
            return f"{x}.memberOfFootprint({quote(self.wildcard(self.pick(f['refs'], 'U1')))})"
        if kind == "hasnetclass":
            fn = rng.choice(["hasNetclass", "hasExactNetclass"])
            return f"{x}.{fn}({quote(self.pick(f['classes'], 'Default'))})"
        if kind == "diffpair":
            return f"{x}.inDiffPair({quote(rng.choice(['*', 'USB_D', 'CLK', 'LVDS0_']))})"
        if kind == "coupled":
            return f"{x}.isCoupledDiffPair()"
        if kind == "L":
            return f"L {eq} {quote(self.pick(f['copper'], 'F.Cu'))}"
        if kind == "locked":
            return ("!" if rng.random() < 0.5 else "") + f"{x}.Locked"
        if kind == "field":
            return f"{x}.getField('Reference') {eq} {quote(self.pick(f['refs'], 'U1'))}"
        if kind == "fpref":
            return f"{x}.memberOfFootprint({quote(self.pick(f['refs'], 'U1'))}) || {x}.Reference == {quote(self.pick(f['refs'], 'U1'))}"
        if kind == "arith":
            op = rng.choice(["<", ">"])
            return f"{x}.Width + {length(rng, 0.0, 0.2)} {op} {length(rng, 0.2, 0.5)}"
        return f"{x}.memberOfSheet('/')"

    def expr(self, depth=0, pair=False):
        rng = self.rng
        r = rng.random()
        if depth < 2 and r < 0.35:
            a = self.expr(depth + 1, pair)
            b = self.expr(depth + 1, pair)
            op = rng.choice(["&&", "&&", "||"])
            s = f"{a} {op} {b}"
            return f"({s})" if rng.random() < 0.6 else s
        if depth < 2 and r < 0.42:
            return f"!({self.expr(depth + 1, pair)})"
        who = rng.choice(["A", "B"]) if pair else "A"
        return self.atom(who)


def constraint(rng, conds, kinds):
    kind = rng.choice(kinds)
    if kind == "clearance":
        return f"(constraint clearance (min {length(rng, 0.05, 0.6)}))", True
    if kind == "hole_clearance":
        return f"(constraint hole_clearance (min {length(rng, 0.0, 0.6)}))", True
    if kind == "edge_clearance":
        return f"(constraint edge_clearance (min {length(rng, 0.1, 1.0)}))", False
    if kind == "track_width":
        parts = []
        if rng.random() < 0.8:
            parts.append(f"(min {length(rng, 0.1, 0.3)})")
        if rng.random() < 0.4:
            parts.append(f"(opt {length(rng, 0.2, 0.4)})")
        if rng.random() < 0.4 or not parts:
            parts.append(f"(max {length(rng, 0.25, 0.5)})")
        return f"(constraint track_width {' '.join(parts)})", False
    if kind == "via_diameter":
        parts = [f"(min {length(rng, 0.4, 0.8)})"] if rng.random() < 0.8 else []
        if rng.random() < 0.4 or not parts:
            parts.append(f"(max {length(rng, 0.6, 1.0)})")
        return f"(constraint via_diameter {' '.join(parts)})", False
    if kind == "hole_size":
        parts = [f"(min {length(rng, 0.2, 0.6)})"] if rng.random() < 0.8 else []
        if rng.random() < 0.4 or not parts:
            parts.append(f"(max {length(rng, 0.5, 2.0)})")
        return f"(constraint hole_size {' '.join(parts)})", False
    if kind == "annular_width":
        parts = [f"(min {length(rng, 0.05, 0.3)})"]
        if rng.random() < 0.2:
            parts.append(f"(max {length(rng, 0.2, 0.8)})")
        return f"(constraint annular_width {' '.join(parts)})", False
    if kind == "hole_to_hole":
        return f"(constraint hole_to_hole (min {length(rng, 0.1, 1.5)}))", True
    if kind == "disallow":
        what = rng.sample(["track", "via", "micro_via", "buried_via", "blind_via", "through_via", "pad", "zone",
                           "text", "graphic", "hole", "footprint"], rng.choice([1, 1, 2, 3]))
        return " ".join(f"(constraint disallow {w})" for w in what) if rng.random() < 0.3 else \
            f"(constraint disallow {' '.join(what)})", False
    if kind == "assertion":
        return f'(constraint assertion "{conds.expr(1)}")', False
    if kind == "physical_clearance":
        return f"(constraint physical_clearance (min {length(rng, 0.05, 0.6)}))", True
    if kind == "physical_hole_clearance":
        return f"(constraint physical_hole_clearance (min {length(rng, 0.05, 0.6)}))", True
    if kind == "thermal_relief_gap":
        return f"(constraint thermal_relief_gap (min {length(rng, 0.2, 0.8)}))", False
    if kind == "thermal_spoke_width":
        parts = [f"(min {length(rng, 0.2, 0.6)})"]
        if rng.random() < 0.5:
            parts.append(f"(opt {length(rng, 0.3, 0.6)})")
        return f"(constraint thermal_spoke_width {' '.join(parts)})", False
    if kind == "zone_connection":
        return f"(constraint zone_connection {rng.choice(['solid', 'thermal_reliefs', 'none'])})", False
    raise ValueError(kind)


DRC_KINDS = ["clearance", "clearance", "clearance", "hole_clearance", "edge_clearance", "track_width", "track_width",
             "via_diameter", "hole_size", "annular_width", "hole_to_hole", "disallow", "disallow", "assertion",
             "assertion", "assertion"]
FILL_KINDS = ["physical_clearance", "physical_hole_clearance", "thermal_relief_gap", "thermal_spoke_width",
              "zone_connection"]


def rules_file(rng, facts, fills):
    conds = Conditions(rng, facts)
    kinds = DRC_KINDS + (FILL_KINDS * 2 if fills else [])
    out = ["(version 1)"]
    for i in range(rng.randint(1, 6)):
        lines = [f"(rule r{i}"]
        if rng.random() < 0.15:
            lines.append(f"  (layer {rng.choice(['outer', 'inner', 'F.Cu', 'B.Cu', quote(rng.choice(facts['copper'] or ['F.Cu']))])})")
        body = []
        pair = False
        for _ in range(rng.choice([1, 1, 2])):
            c, two = constraint(rng, conds, kinds)
            pair = pair or two
            body.append(f"  {c}")
        if rng.random() < 0.85:
            # (now and then as KiCad's files write a condition: in double quotes, its strings in single ones)
            lines.append(f'  (condition "{conds.expr(0, pair)}")')
        lines += body
        if rng.random() < 0.15:
            lines.append(f"  (severity {rng.choice(['error', 'warning', 'ignore', 'exclusion'])})")
        lines.append(")")
        out.append("\n".join(lines))
    text = "\n\n".join(out) + "\n"
    # now and then a rule KiCad cannot read (no rules at all, then) or compile (the rules before it kept)
    r = rng.random()
    if r < 0.03:
        text += "\n(rule broken (condition \"A.NetClass == 'Default'\") (constraint clearance (min 0.2mm))\n"
    elif r < 0.06:
        text += "\n(rule unknown (condition \"A.No_Such_Property == 1mm\") (constraint clearance (min 0.3mm)))\n"
    elif r < 0.08:
        text += "\n(rule unitless (condition \"A.Width > 0.2\") (constraint track_width (min 0.15mm)))\n"
    elif r < 0.09:
        text += "\n(rule function (condition \"A.noSuchFunction('x')\") (constraint clearance (min 0.3mm)))\n"
    return text


def main():
    args = sys.argv[1:]
    fills = "--fills" in args
    every = "--all" in args
    seed = 20261029
    if "--seed" in args:
        k = args.index("--seed")
        seed = int(args[k + 1])
        del args[k:k + 2]
    boards = [a for a in args if not a.startswith("--")]
    written = 0
    for board in boards:
        name = os.path.splitext(os.path.basename(board))[0]
        rng = random.Random(f"rules-{name}-{seed}")
        out = os.path.splitext(board)[0] + ".kicad_dru"
        if not every and rng.random() < 1 / 3:
            if os.path.exists(out):
                os.remove(out)
            continue
        with open(out, "w") as f:
            f.write(rules_file(rng, board_facts(board), fills))
        written += 1
    print(f"rules for {written} of {len(boards)} boards")


if __name__ == "__main__":
    main()
