#!/usr/bin/env python3
"""Boards of random stackups, and the board's thickness between each two of their copper layers as KiCad's length
calculation counts it for a via (LENGTH_DELAY_CALCULATION::StackupHeight: BOARD_STACKUP::GetLayerDistance of the
board's stackup, or of the default stackup KiCad builds for a board with none, from its thickness and layers), which
a length tuning adds to a path's length for each via on it.

KiCad's Python module does not reach the stackup, so the heights are read from kicad-cli's DRC: each board has, for
each pair of its copper layers, a net of a track on the one, a through via and a track on the other, and a rule that
no net may be longer than a micrometre; the DRC reports each net's length (to a tenth of a micrometre), whose tracks'
lengths are known: the rest is the via's height. Each board (`stackups.py OUTDIR COUNT [SEED]`) has two to eight copper
layers, a stackup of its own (copper and dielectrics of random thicknesses, dielectrics of up to three sublayers, now
and then a thickness not given, which KiCad takes as its default or none; solder masks and silkscreens) or none (KiCad's
default, from the board's thickness, now and then a mask layer left out of the board's layers), and now and then a
project that does not use heights for lengths. Each is written with its project and, next to it, BOARD.stackup
(JSON: each pair of layers, by name, and KiCad's height between them, in nm).

    stackups.py OUTDIR COUNT [SEED]
"""

import json
import os
import random
import re
import subprocess
import sys
import tempfile
import uuid

LAYER_IDS = {"F.Cu": 0, "B.Cu": 2}
OTHER_LAYERS = [(9, "F.Adhes", "user", "F.Adhesive"), (11, "B.Adhes", "user", "B.Adhesive"), (13, "F.Paste", "user", None),
                (15, "B.Paste", "user", None), (5, "F.SilkS", "user", "F.Silkscreen"), (7, "B.SilkS", "user", "B.Silkscreen"),
                (1, "F.Mask", "user", None), (3, "B.Mask", "user", None), (17, "Dwgs.User", "user", "User.Drawings"),
                (19, "Cmts.User", "user", "User.Comments"), (25, "Edge.Cuts", "user", None), (27, "Margin", "user", None),
                (31, "F.CrtYd", "user", "F.Courtyard"), (29, "B.CrtYd", "user", "B.Courtyard"), (35, "F.Fab", "user", None),
                (33, "B.Fab", "user", None)]


def copper_names(n):
    return ["F.Cu"] + [f"In{i}.Cu" for i in range(1, n - 1)] + ["B.Cu"]


def mm(nm):
    return f"{nm / 1_000_000:.6f}".rstrip("0").rstrip(".")


def board(rng, n):
    """A board of `n` copper layers: its text, the nets' track lengths (nm) by name and the layers they join"""
    names = copper_names(n)
    masks = [m for m in ("F.Mask", "B.Mask") if rng.random() < 0.85]
    layers = ["\t\t(0 \"F.Cu\" signal)"]
    for i in range(1, n - 1):
        layers.append(f"\t\t({2 + 2 * i} \"In{i}.Cu\" signal)")
    layers.append("\t\t(2 \"B.Cu\" signal)")
    for lid, name, kind, user in OTHER_LAYERS:
        if name.endswith("Mask") and name not in masks:
            continue
        layers.append(f"\t\t({lid} \"{name}\" {kind}" + (f" \"{user}\"" if user else "") + ")")
    thickness = rng.randint(80, 240) * 10_000
    setup = ["\t\t(pad_to_mask_clearance 0)"]
    if rng.random() < 0.55:
        # (a stackup of its own, top to bottom)
        st = ["\t\t(stackup"]
        st.append("\t\t\t(layer \"F.SilkS\" (type \"Top Silk Screen\"))")
        if "F.Mask" in masks:
            st.append(f"\t\t\t(layer \"F.Mask\" (type \"Top Solder Mask\") (thickness {mm(rng.randint(5, 30) * 1000)}))")
        for i, name in enumerate(names):
            cu = rng.choice([17_500, 35_000, 35_000, 70_000, rng.randint(9, 105) * 1000])
            st.append(f"\t\t\t(layer \"{name}\" (type \"copper\")"
                      + ("" if rng.random() < 0.1 else f" (thickness {mm(cu)})") + ")")
            if i == n - 1:
                break
            # (its sublayers' thicknesses, now and then one not given, or locked)
            subs = []
            for _ in range(rng.choice([1, 1, 1, 2, 3])):
                if rng.random() < 0.05:
                    subs.append("")
                else:
                    subs.append(f" (thickness {mm(rng.randint(50, 1600) * 1000)}" + (" locked" if rng.random() < 0.1 else "")
                                + ")")
            kind = "core" if i % 2 == 0 else "prepreg"
            st.append(f"\t\t\t(layer \"dielectric {i + 1}\" (type \"{kind}\")" + subs[0]
                      + " (material \"FR4\") (epsilon_r 4.5) (loss_tangent 0.02)"
                      + "".join(f" addsublayer{s} (material \"FR4\") (epsilon_r 4.5) (loss_tangent 0.02)" for s in subs[1:])
                      + ")")
        if "B.Mask" in masks:
            st.append(f"\t\t\t(layer \"B.Mask\" (type \"Bottom Solder Mask\") (thickness {mm(rng.randint(5, 30) * 1000)}))")
        st.append("\t\t\t(layer \"B.SilkS\" (type \"Bottom Silk Screen\"))")
        st.append("\t\t\t(copper_finish \"None\")")
        st.append("\t\t\t(dielectric_constraints no)")
        st.append("\t\t)")
        setup = st + setup
    # one net for each pair of layers: a track on the one, a through via, a track on the other
    items = []
    nets = {}
    x, y = 100_000_000, 100_000_000
    k = 0
    pairs = [(a, b) for a in range(n) for b in range(n) if a != b and (a < b or rng.random() < 0.2)]
    for a, b in pairs:
        k += 1
        net = f"N{k}"
        l1 = rng.randint(10, 60) * 100_000
        l2 = rng.randint(10, 60) * 100_000
        px, py = x + (k % 8) * 8_000_000, y + (k // 8) * 8_000_000
        items.append(f"\t(segment (start {mm(px)} {mm(py)}) (end {mm(px + l1)} {mm(py)}) (width 0.25) (layer \"{names[a]}\")"
                     f" (net \"{net}\") (uuid \"{uuid.UUID(int=rng.getrandbits(128))}\"))")
        items.append(f"\t(via (at {mm(px + l1)} {mm(py)}) (size 0.6) (drill 0.3) (layers \"F.Cu\" \"B.Cu\") (net \"{net}\")"
                     f" (uuid \"{uuid.UUID(int=rng.getrandbits(128))}\"))")
        items.append(f"\t(segment (start {mm(px + l1)} {mm(py)}) (end {mm(px + l1)} {mm(py + l2)}) (width 0.25)"
                     f" (layer \"{names[b]}\") (net \"{net}\") (uuid \"{uuid.UUID(int=rng.getrandbits(128))}\"))")
        nets[net] = (l1 + l2, names[a], names[b])
    w, h = 8 * 8_000_000 + 10_000_000, (k // 8 + 1) * 8_000_000 + 10_000_000
    corners = [(x - 5_000_000, y - 5_000_000), (x - 5_000_000 + w, y - 5_000_000), (x - 5_000_000 + w, y - 5_000_000 + h),
               (x - 5_000_000, y - 5_000_000 + h)]
    for i in range(4):
        (ax, ay), (bx, by) = corners[i], corners[(i + 1) % 4]
        items.append(f"\t(gr_line (start {mm(ax)} {mm(ay)}) (end {mm(bx)} {mm(by)}) (stroke (width 0.05) (type default))"
                     f" (layer \"Edge.Cuts\") (uuid \"{uuid.UUID(int=rng.getrandbits(128))}\"))")
    text = ("(kicad_pcb\n\t(version 20260206)\n\t(generator \"pcbnew\")\n\t(generator_version \"10.0\")\n"
            f"\t(general\n\t\t(thickness {mm(thickness)})\n\t\t(legacy_teardrops no)\n\t)\n\t(paper \"A4\")\n"
            "\t(layers\n" + "\n".join(layers) + "\n\t)\n\t(setup\n" + "\n".join(setup) + "\n\t)\n"
            + "\n".join(items) + "\n)\n")
    return text, nets


def main():
    out, count = sys.argv[1], int(sys.argv[2])
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 20261109
    rng = random.Random(seed)
    os.makedirs(out, exist_ok=True)
    for i in range(count):
        n = rng.choice([2, 2, 4, 4, 6, 8])
        text, nets = board(rng, n)
        name = os.path.join(out, f"stackup-{seed}-{i}")
        with open(name + ".kicad_pcb", "w") as f:
            f.write(text)
        use_height = rng.random() < 0.9
        project = {"board": {"design_settings": {"rules": {"use_height_for_length_calcs": use_height}}},
                   "meta": {"filename": os.path.basename(name) + ".kicad_pro", "version": 3}}
        with open(name + ".kicad_pro", "w") as f:
            json.dump(project, f, indent=2)
        # (KiCad's DRC of it, every net too long, its length said)
        with tempfile.TemporaryDirectory() as tmp:
            for ext in (".kicad_pcb", ".kicad_pro"):
                with open(name + ext) as src, open(os.path.join(tmp, "b" + ext), "w") as dst:
                    dst.write(src.read())
            with open(os.path.join(tmp, "b.kicad_dru"), "w") as f:
                f.write("(version 1)\n(rule \"len\" (condition \"A.NetName != ''\") (constraint length (max 0.001mm)))\n")
            report_path = os.path.join(tmp, "drc.json")
            subprocess.run(["kicad-cli", "pcb", "drc", "--format", "json", "--units", "mm", "--severity-all", "-o",
                            report_path, os.path.join(tmp, "b.kicad_pcb")], check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            with open(report_path) as f:
                report = json.load(f)
        heights = []
        for v in report["violations"]:
            if v["type"] != "length_out_of_range":
                continue
            actual = re.search(r"actual ([0-9.]+) mm", v["description"])
            net = next((re.search(r"\[(N[0-9]+)\]", it["description"]).group(1) for it in v["items"]
                        if re.search(r"\[(N[0-9]+)\]", it["description"])), None)
            if not actual or net not in nets:
                continue
            length, a, b = nets[net]
            heights.append({"layers": [a, b], "height": round(float(actual.group(1)) * 1_000_000) - length})
        if len(heights) != len(nets):
            sys.exit(f"{name}: KiCad's DRC gave {len(heights)} lengths for {len(nets)} nets")
        heights.sort(key=lambda h: h["layers"])
        with open(name + ".stackup", "w") as f:
            json.dump({"heights": heights}, f, indent=1)
            f.write("\n")
    print(f"{out}: {count} boards")


if __name__ == "__main__":
    main()
