#!/usr/bin/env python3
"""Random boards, and routes to make on them, routed by KiCad's own router (kicad-router, which build.sh builds).

Each board has pads of a few nets (rectangles, circles, ovals, turned rectangles as polygons; surface mount on one
side or through-hole with a drill, now and then a hole with no plating), tracks already on it, and an outline. Each
route starts on a pad and goes, by a pointer path that wanders and now and then crosses an obstacle, to a pad of its
net, where it is fixed; some stop short and are fixed mid-way. Some place vias on the way, switch layers, fix parts
of the route as they go and take them back, or flip the posture; some mark obstacles instead of walking around them. What KiCad does with them goes, with the boards, into
the fixture KiCadRouterTests checks the Swift port against.

    scenes.py KICAD_ROUTER OUT.json [COUNT [SEED]]
    scenes.py --boards KICAD_ROUTER OUT.json ROUTES_PER_BOARD SEED SCENE.json...   (real boards, from board-scene.py)
"""

import json
import random
import subprocess
import sys

MM = 1_000_000


def pad(rng, net, pos, layers, through):
    x, y = pos
    kind = rng.choice(["rect", "rect", "circle", "oval", "turned"])
    w = rng.randint(4, 20) * 50_000
    h = rng.randint(4, 20) * 50_000
    if kind == "rect":
        shape = {"rect": [x - w // 2, y - h // 2], "size": [w, h]}
    elif kind == "circle":
        shape = {"circle": [x, y], "r": w // 2}
    elif kind == "oval":
        half = abs(w - h) // 2
        if w > h:
            shape = {"segment": [[x - half, y], [x + half, y]], "w": h}
        else:
            shape = {"segment": [[x, y - half], [x, y + half]], "w": w}
    else:
        # a rectangle turned 45 degrees, as KiCad makes it a polygon
        a, b = w // 2, h // 2
        k = 707_107  # sqrt(1/2), in millionths
        def rot(px, py):
            return [x + (px * k - py * k) // 1_000_000, y + (px * k + py * k) // 1_000_000]
        shape = {"simple": [rot(-a, -b), rot(a, -b), rot(a, b), rot(-a, b)]}
    p = {"kind": "pad", "net": net, "layers": layers, "pos": [x, y], "shape": shape}
    if through:
        drill = min(w, h) * rng.randint(3, 6) // 10
        p["hole"] = {"segment": [[x, y], [x, y]], "w": max(drill, 200_000)}
        if rng.random() < 0.08:
            p["npth"] = True
            p["net"] = 0
    return p


def board(rng, n):
    # two copper layers mostly, now and then four; now and then a small board crowded with pads and tracks
    copper = rng.choice([2, 2, 2, 4])
    last = copper - 1
    dense = rng.random() < 0.25
    size = rng.randint(12, 20) * MM if dense else rng.randint(20, 40) * MM
    gap = 1_200_000 if dense else 1_800_000
    items = []
    # the outline
    c = [[0, 0], [size, 0], [size, size], [0, size]]
    for i in range(4):
        items.append({"kind": "edge", "shape": {"segment": [c[i], c[(i + 1) % 4]], "w": 0}})
    nets = rng.randint(2, 6)
    used = []
    for _ in range(rng.randint(8, 28)):
        for _ in range(50):
            x = rng.randint(2 * MM, size - 2 * MM) // 50_000 * 50_000
            y = rng.randint(2 * MM, size - 2 * MM) // 50_000 * 50_000
            if all(abs(x - u) > gap or abs(y - v) > gap for u, v in used):
                break
        used.append((x, y))
        layers = rng.choice([[0, 0], [0, 0], [last, last], [0, last], [0, last]])
        items.append(pad(rng, rng.randint(1, nets), (x, y), layers, layers == [0, last]))
    # tracks already there
    for _ in range(rng.randint(0, 12 if dense else 6)):
        a = [rng.randint(2 * MM, size - 2 * MM), rng.randint(2 * MM, size - 2 * MM)]
        if rng.random() < 0.5:
            b = [a[0] + rng.randint(-8, 8) * MM, a[1]]
        else:
            d = rng.randint(-6, 6) * MM
            b = [a[0] + d, a[1] + d * rng.choice([1, -1])]
        if a != b:
            items.append({"kind": "track", "net": rng.randint(1, nets), "layer": rng.randint(0, last), "a": a, "b": b,
                          "width": rng.randint(3, 8) * 50_000})
    rules = {"clearance": rng.choice([150_000, 200_000, 250_000]), "holeClearance": 250_000, "holeToHole": 250_000,
             "edgeClearance": rng.choice([300_000, 500_000])}
    return {"layers": copper, "rules": rules, "items": items, "routes": routes(rng, items, copper, (0, 0, size, size))}


def routes(rng, items, copper, area, count=None):
    """Random routes from pads of the board in `area` (x0, y0, x1, y1): to a pad of their net mostly, else anywhere"""
    out = []
    x0, y0, x1, y1 = area
    last = copper - 1

    def flashed(it, l):
        return it["layers"][0] <= l <= it["layers"][1] and ("flashed" not in it or it["flashed"][l])

    pads = [i for i, it in enumerate(items) if it["kind"] == "pad" and not it.get("npth")
            and any(flashed(it, l) for l in range(copper))]
    if not pads:
        return out
    for _ in range(rng.randint(1, 4) if count is None else count):
        a = rng.choice(pads)
        same = [i for i in pads if i != a and items[i]["net"] == items[a]["net"]]
        start = items[a]["pos"]
        layer = rng.choice([l for l in range(copper) if flashed(items[a], l)])
        route = {"start": start, "startItem": a, "layer": layer, "width": rng.randint(3, 8) * 50_000}
        if rng.random() < 0.2:
            route["mode"] = "mark"
        if rng.random() < 0.5:
            route["viaDiameter"] = rng.randint(5, 9) * 100_000
            route["viaDrill"] = route["viaDiameter"] * rng.randint(4, 6) // 10 // 50_000 * 50_000
        b = None
        if same and rng.random() < 0.8:
            b = rng.choice(same)
            end = items[b]["pos"]
        else:
            end = [rng.randint(x0 + MM, x1 - MM), rng.randint(y0 + MM, y1 - MM)]
        steps = rng.randint(2, 7)
        points = []
        for s in range(1, steps + 1):
            t = s / steps
            px = int(start[0] + (end[0] - start[0]) * t)
            py = int(start[1] + (end[1] - start[1]) * t)
            if s < steps:
                px += rng.randint(-3, 3) * 400_000
                py += rng.randint(-3, 3) * 400_000
            points.append([px, py])
        # now and then, on the way, what the router tool asks of the router when a key is pressed or the pointer is
        # clicked: a via (the layer pair, via placement on, a click, the other layer), the layer switched at the
        # start, a part fixed with a click (and now and then taken back), the posture flipped; each followed, as the
        # tool does, by a move to where the pointer is
        events = {}
        for _ in range(2):
            if steps > 1 and rng.random() < 0.3:
                events[rng.randint(1, steps - 1)] = "via"
        for kind, chance in (("fix", 0.15), ("undo", 0.1), ("posture", 0.1)):
            if steps > 1 and rng.random() < chance:
                events.setdefault(rng.randint(1, steps - 1), kind)
        current = layer
        moves = []
        for s, p in enumerate(points, 1):
            moves.append(p)
            if s == 1 and items[a]["layers"] == [0, last] and rng.random() < 0.15:
                current = rng.choice([l for l in range(copper) if l != current])
                moves += [{"layer": current}, p]
            event = events.get(s)
            if event == "via":
                target = rng.choice([l for l in range(copper) if l != current])
                moves += [{"pair": [current, target]}, {"via": "on"}, p, {"fix": p, "endItem": -1}, {"layer": target}, p]
                current = target
            elif event == "fix":
                moves += [{"fix": p, "endItem": -1}, p]
            elif event == "undo":
                moves += [{"fix": p, "endItem": -1}, {"undo": True}, p]
            elif event == "posture":
                moves += [{"posture": True}, p]
        route["moves"] = moves
        if b is not None and flashed(items[b], current):
            route["endItem"] = b
        if rng.random() < 0.85:
            route["fix"] = points[-1]
        out.append(route)
    return out


def board_area(scene):
    """The box round a board's edge, or its pads"""
    xs, ys = [], []
    for it in scene["items"]:
        shape = it.get("shape", {})
        pts = shape.get("segment") or shape.get("arc") or shape.get("simple") or ([it["pos"]] if "pos" in it else [])
        if it["kind"] == "edge" or not any(i["kind"] == "edge" for i in scene["items"]):
            for p in pts:
                xs.append(p[0])
                ys.append(p[1])
    return (min(xs), min(ys), max(xs), max(ys))


def boards(router, out, files, per_board, seed):
    """Real boards (board-scene.py's scenes, from KiCad's own reading of them), each with routes, routed by KiCad"""
    rng = random.Random(seed)
    cases = []
    for path in files:
        with open(path) as f:
            scene = json.load(f)
        name = path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
        area = board_area(scene)
        for k in range(per_board):
            case = dict(scene)
            case["routes"] = routes(rng, scene["items"], scene["layers"], area, count=rng.randint(2, 6))
            if not case["routes"]:
                continue
            result = subprocess.run([router], input=json.dumps(case), capture_output=True, text=True, check=True)
            cases.append({"name": f"{name}-{seed}-{k}", "scene": case, "kicad": json.loads(result.stdout)})
    with open(out, "w") as f:
        json.dump(cases, f, separators=(",", ":"))
    print(f"{out}: {len(cases)} cases on {len(files)} boards, {sum(len(c['kicad']) for c in cases)} routes")


def main():
    if sys.argv[1] == "--boards":
        # scenes.py --boards KICAD_ROUTER OUT.json PER_BOARD SEED SCENE.json...
        boards(sys.argv[2], sys.argv[3], sys.argv[6:], int(sys.argv[4]), int(sys.argv[5]))
        return
    router, out = sys.argv[1], sys.argv[2]
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    seed = int(sys.argv[4]) if len(sys.argv) > 4 else 20261016
    rng = random.Random(seed)
    cases = []
    for n in range(count):
        scene = board(rng, n)
        result = subprocess.run([router], input=json.dumps(scene), capture_output=True, text=True, check=True)
        cases.append({"name": f"random-{seed}-{n}", "scene": scene, "kicad": json.loads(result.stdout)})
    with open(out, "w") as f:
        json.dump(cases, f, separators=(",", ":"))
    print(f"{out}: {count} boards, {sum(len(c['kicad']) for c in cases)} routes")


if __name__ == "__main__":
    main()
