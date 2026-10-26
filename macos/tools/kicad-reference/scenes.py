#!/usr/bin/env python3
"""Random boards, and routes to make on them, routed by KiCad's own router (kicad-router, which build.sh builds).

Each board has pads of a few nets (rectangles, circles, ovals, turned rectangles as polygons; surface mount on one
side or through-hole with a drill, now and then a hole with no plating), tracks already on it, and an outline. Each
route starts on a pad (now and then on a hole with no plating, where the router refuses to start) and goes, by a
pointer path that wanders and now and then crosses an obstacle, to a pad of its net, where it is fixed; some stop short and are fixed mid-way. Some place vias on the way, switch layers, fix parts
of the route as they go and take them back, or flip the posture; some mark obstacles instead of walking around them. What KiCad does with them goes, with the boards, into
the fixture KiCadRouterTests checks the Swift port against.

With `--mode shove`, the routes shove what is in their way (most of them; a few walk round it or mark it), on boards
with more to shove: tracks of a few segments at 45 and 90 degrees, some from pads, some through vias to another
layer, some locked, and vias of their own; what a route shoves aside is taken off the board for the routes after it
("removeItems"), and after each step the board as the router has it then (what it has shoved where, and what has
sprung back) is written too, when it has changed. `--mode mix` mixes the three modes evenly on such boards.
`--shoving` keeps only the boards on which KiCad's router shoved something. A board on which an undo would leave
KiCad's shove holding a branch the undo deletes is left out (router.cpp stops there, with exit status 3: what KiCad
does next is undefined), and another made in its place.

With `--mode drag`, the routes are drags instead, on boards like the shove mode's: of a track's segment (grabbed
along it) or corner (grabbed within half its width of its end, or right on it), or of a via, now and then at free
angles, walking round what is in the way, shoving it or marking it; the pointer taken away and now and then back,
and clicked to keep the drag (now and then with Ctrl, to keep it whatever it collides with); now and then the whole
dragged track optimized, or its segments not smoothed. Each drag is chosen on the board as the drags before it left
it (KiCad's router is run on those to know), so a track already dragged can be dragged again. `--shoving` keeps only
the boards on which a drag shoved another net's track or via.

    scenes.py [--mode shove|mix|drag] [--shoving] KICAD_ROUTER OUT.json [COUNT [SEED]]
    scenes.py [--mode shove|mix|drag] --boards KICAD_ROUTER OUT.json ROUTES_PER_BOARD SEED SCENE.json...   (real
        boards, from board-scene.py)
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


def polylines(rng, items, size, nets, copper, dense):
    """Tracks to shove: lines of a few segments at 45 and 90 degrees, some from pads of their net, some going on
    through a via on another layer, some locked; and vias on their own"""
    last = copper - 1
    lo, hi = 2 * MM, size - 2 * MM
    dirs = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    pads = [it for it in items if it["kind"] == "pad" and not it.get("npth")]

    def line(start, net, layer, width, locked):
        p = start
        d = rng.randrange(8)
        for _ in range(rng.randint(1, 4)):
            # (on, or a turn of 45 or 90 degrees)
            d = (d + rng.choice([0, 1, -1, 2, -2])) % 8
            step = rng.randint(2, 12) * 250_000
            q = [p[0] + dirs[d][0] * step, p[1] + dirs[d][1] * step]
            if not (lo <= q[0] <= hi and lo <= q[1] <= hi):
                break
            t = {"kind": "track", "net": net, "layer": layer, "a": p, "b": q, "width": width}
            if locked:
                t["locked"] = True
            items.append(t)
            p = q
        return p

    for _ in range(rng.randint(2, 10 if dense else 7)):
        width = rng.randint(3, 8) * 50_000
        locked = rng.random() < 0.08
        if pads and rng.random() < 0.3:
            # (from a pad, on a layer it is on)
            pd = rng.choice(pads)
            net, start = pd["net"], pd["pos"]
            layer = rng.randint(pd["layers"][0], pd["layers"][1])
        else:
            net = rng.randint(1, nets)
            start = [rng.randint(lo, hi) // 50_000 * 50_000, rng.randint(lo, hi) // 50_000 * 50_000]
            layer = rng.randint(0, last)
        end = line(start, net, layer, width, locked)
        if end != start and rng.random() < 0.35:
            # (a via at its end, and now and then the track going on from it on another layer)
            diameter = rng.randint(5, 8) * 100_000
            items.append({"kind": "via", "net": net, "pos": end, "layers": [0, last], "diameter": diameter,
                          "drill": diameter * rng.randint(4, 6) // 10 // 50_000 * 50_000})
            if rng.random() < 0.6:
                line(end, net, rng.choice([l for l in range(copper) if l != layer]), width, locked)
    # vias with no tracks on them
    for _ in range(rng.randint(0, 3)):
        diameter = rng.randint(5, 8) * 100_000
        items.append({"kind": "via", "net": rng.randint(1, nets),
                      "pos": [rng.randint(lo, hi) // 50_000 * 50_000, rng.randint(lo, hi) // 50_000 * 50_000],
                      "layers": [0, last], "diameter": diameter,
                      "drill": diameter * rng.randint(4, 6) // 10 // 50_000 * 50_000})


def board(rng, n, mode="walkaround"):
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
    if mode != "walkaround":
        polylines(rng, items, size, nets, copper, dense)
    if mode == "drag":
        # (more of them, to drag and to drag into)
        polylines(rng, items, size, nets, copper, dense)
    rules = {"clearance": rng.choice([150_000, 200_000, 250_000]), "holeClearance": 250_000, "holeToHole": 250_000,
             "edgeClearance": rng.choice([300_000, 500_000])}
    # (drags are chosen later, each on the board as the drags before it left it)
    scene = {"layers": copper, "rules": rules, "items": items,
             "routes": [] if mode == "drag" else routes(rng, items, copper, (0, 0, size, size), mode=mode)}
    if mode != "walkaround":
        scene["removeItems"] = True
    return scene


def route_mode(rng, mode):
    """The mode a route is made in: walk round, now and then mark obstacles (the default); shove mostly; or any"""
    if mode == "shove":
        r = rng.random()
        return "shove" if r < 0.88 else "mark" if r < 0.94 else "walkaround"
    if mode == "mix":
        return rng.choice(["shove", "walkaround", "mark"])
    return "mark" if rng.random() < 0.2 else "walkaround"


def routes(rng, items, copper, area, count=None, mode="walkaround"):
    """Random routes from pads of the board in `area` (x0, y0, x1, y1): to a pad of their net mostly, else anywhere"""
    out = []
    x0, y0, x1, y1 = area
    last = copper - 1

    def flashed(it, l):
        return it["layers"][0] <= l <= it["layers"][1] and ("flashed" not in it or it["flashed"][l])

    pads = [i for i, it in enumerate(items) if it["kind"] == "pad" and not it.get("npth")
            and any(flashed(it, l) for l in range(copper))]
    holes = [i for i, it in enumerate(items) if it["kind"] == "pad" and it.get("npth")]
    if not pads:
        return out
    for _ in range(rng.randint(1, 4) if count is None else count):
        a = rng.choice(pads)
        # (now and then from a hole with no plating instead, which KiCad's router will not start from)
        unplated = bool(holes) and rng.random() < 0.05
        if unplated:
            a = rng.choice(holes)
        same = [i for i in pads if i != a and items[i]["net"] == items[a]["net"]]
        start = items[a]["pos"]
        layer = rng.choice(list(range(items[a]["layers"][0], items[a]["layers"][1] + 1)) if unplated
                           else [l for l in range(copper) if flashed(items[a], l)])
        route = {"start": start, "startItem": a, "layer": layer, "width": rng.randint(3, 8) * 50_000}
        m = route_mode(rng, mode)
        if m != "walkaround":
            route["mode"] = m
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


def drag(rng, items, area):
    """A random drag of one of `items`' tracks or vias, as the router tool's drag (D) or free angle drag (G) starts one
    with the pointer on it, and the pointer's way from there; None if there is nothing to drag"""
    x0, y0, x1, y1 = area
    tracks = [i for i, it in enumerate(items) if it["kind"] == "track" and it["a"] != it["b"]]
    vias = [i for i, it in enumerate(items) if it["kind"] == "via"]
    if not tracks and not vias:
        return None
    if vias and (not tracks or rng.random() < 0.3):
        i = rng.choice(vias)
        grabbed = "via"
        at = list(items[i]["pos"])
        if rng.random() < 0.3:
            # (off its centre, on it)
            r = items[i]["diameter"] // 5
            at = [at[0] + rng.randint(-r, r), at[1] + rng.randint(-r, r)]
    else:
        i = rng.choice(tracks)
        a, b, w = items[i]["a"], items[i]["b"], items[i]["width"]
        grab = rng.random()
        grabbed = "segment" if grab < 0.5 else "corner"
        if grab < 0.5:
            # (along the segment)
            t = rng.uniform(0.2, 0.8)
            at = [int(a[0] + (b[0] - a[0]) * t), int(a[1] + (b[1] - a[1]) * t)]
        else:
            # (at its corner: within half its width of an end, or right on it)
            e = rng.choice([a, b])
            r = w // 5 if grab < 0.85 else 0
            at = [e[0] + rng.randint(-r, r), e[1] + rng.randint(-r, r)]
    r = rng.random()
    mode = "shove" if r < 0.5 else "walkaround" if r < 0.8 else "mark"
    d = {"item": i, "at": at}
    if rng.random() < 0.12:
        d["freeAngle"] = True
    route = {"drag": d, "mode": mode}
    if rng.random() < 0.2:
        route["optimizeEntire"] = True
    if rng.random() < 0.15:
        route["smooth"] = False
    if mode == "mark" and rng.random() < 0.3:
        # (KiCad's "allow DRC violations", which marking obstacles keeps any drag)
        route["allowViolations"] = True
    # the pointer taken somewhere near (mostly to another net's track, via or pad near by, into it or past it), by
    # the way it wanders, now and then back towards where it started
    net = items[i].get("net")
    kinds = ("track", "via", "pad") if rng.random() < 0.25 else ("track", "via")
    near = []
    layer = items[i].get("layer")
    for it in items:
        if it.get("net") == net or it["kind"] not in kinds:
            continue
        # (on the dragged track's layer)
        lo, hi = it.get("layers") or [it.get("layer")] * 2
        if layer is not None and not lo <= layer <= hi:
            continue
        p = it["pos"] if "pos" in it else [(it["a"][0] + it["b"][0]) // 2, (it["a"][1] + it["b"][1]) // 2]
        if abs(p[0] - at[0]) + abs(p[1] - at[1]) < 5 * MM:
            near.append(p)
    # (or now and then to a corner of its own net's tracks on its layer, or near it, where the dragged corner or
    # segment snaps to the line of another, as KiCad smooths a drag)
    def parallel(it):
        if "a" not in items[i]:
            return True
        (ax, ay), (bx, by) = items[i]["a"], items[i]["b"]
        (cx, cy), (dx, dy) = it["a"], it["b"]
        return (bx - ax) * (dy - cy) == (by - ay) * (dx - cx)
    own = [p for it in items if it["kind"] == "track" and it.get("net") == net and it.get("layer") == layer
           and it is not items[i] and (grabbed != "segment" or parallel(it)) for p in (it["a"], it["b"])]
    w = items[i].get("width", 0)
    if own and rng.random() < 0.2:
        p = rng.choice(own)
        end = [p[0] + rng.randint(-w // 2, w // 2), p[1] + rng.randint(-w // 2, w // 2)]
    elif near and rng.random() < 0.8:
        p = rng.choice(near)
        over = rng.uniform(0.8, 1.2)
        end = [int(at[0] + (p[0] - at[0]) * over), int(at[1] + (p[1] - at[1]) * over)]
    else:
        span = rng.choice([4, 8, 12])
        end = [at[0] + rng.randint(-span, span) * 250_000, at[1] + rng.randint(-span, span) * 250_000]
    end = [min(max(end[0], x0), x1), min(max(end[1], y0), y1)]
    steps = rng.randint(1, 6)
    moves = []
    for s in range(1, steps + 1):
        t = s / steps
        px = int(at[0] + (end[0] - at[0]) * t)
        py = int(at[1] + (end[1] - at[1]) * t)
        if s < steps:
            px += rng.randint(-2, 2) * 150_000
            py += rng.randint(-2, 2) * 150_000
        moves.append([px, py])
    if rng.random() < 0.2:
        back = rng.uniform(0.2, 0.9)
        moves.append([int(end[0] + (at[0] - end[0]) * back), int(end[1] + (at[1] - end[1]) * back)])
    if rng.random() < 0.15:
        # (the pointer still, as it is between moves the grid snaps to the same point)
        k = rng.randrange(len(moves))
        moves.insert(k, moves[k])
    if rng.random() < 0.1:
        # (a click on the way, which ends the drag if the dragger keeps it)
        k = rng.randrange(len(moves))
        click = {"fix": moves[k]}
        if rng.random() < 0.3:
            click["force"] = True
        moves.insert(k + 1, click)
    route["moves"] = moves
    if rng.random() < 0.85:
        route["fix"] = moves[-1] if isinstance(moves[-1], list) else moves[-2]
        if rng.random() < 0.3:
            route["force"] = True
    return route


def drag_routes(router, rng, scene, area, count):
    """`count` drags on the scene's board, each chosen on the board as the drags before it left it (KiCad's router run
    on those to know), and what KiCad's router made of them (None if what it does is undefined); and how many of them
    shoved another net's track or via, on the way or in the end"""
    items = list(scene["items"])
    drags, kicad, shoving = [], [], 0
    for _ in range(count):
        d = drag(rng, items, area)
        if d is None:
            break
        drags.append(d)
        kicad = route(router, dict(scene, routes=drags))
        if kicad is None:
            return None, 0
        r = kicad[-1]
        net = items[d["drag"]["item"]].get("net")
        removed = set(r.get("removed", []))
        for m in r["moves"]:
            removed |= set((m.get("node") or {}).get("removed", []))
        if any(items[k].get("net") != net for k in removed):
            shoving += 1
        for k in reversed(r.get("removed", [])):
            del items[k]
        items += r["added"]
    return (drags, kicad), shoving


def route(router, scene):
    """What KiCad's router makes of the scene's routes; None if what it does is undefined (router.cpp's exit status
    3: an undo of a shoving route that KiCad's line placer gets wrong, reading a node it has deleted)"""
    result = subprocess.run([router], input=json.dumps(scene), capture_output=True, text=True)
    if result.returncode == 3:
        return None
    if result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, router, result.stdout, result.stderr)
    return json.loads(result.stdout)


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


def boards(router, out, files, per_board, seed, mode="walkaround"):
    """Real boards (board-scene.py's scenes, from KiCad's own reading of them), each with routes, routed by KiCad"""
    rng = random.Random(seed)
    cases = []
    undefined = 0
    drags = shoves = 0
    for path in files:
        with open(path) as f:
            scene = json.load(f)
        name = path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
        area = board_area(scene)
        for k in range(per_board):
            case = dict(scene)
            if mode == "drag":
                case["removeItems"] = True
                done, shoving = drag_routes(router, rng, case, area, rng.randint(2, 6))
                if done is None:
                    undefined += 1
                    continue
                case["routes"], kicad = done
                drags += len(case["routes"])
                shoves += shoving
                cases.append({"name": f"{name}-drag-{seed}-{k}", "scene": case, "kicad": kicad})
                continue
            case["routes"] = routes(rng, scene["items"], scene["layers"], area, count=rng.randint(2, 6), mode=mode)
            if not case["routes"]:
                continue
            if mode != "walkaround":
                case["removeItems"] = True
            kicad = route(router, case)
            if kicad is None:
                undefined += 1
                continue
            tag = "" if mode == "walkaround" else f"{mode}-"
            cases.append({"name": f"{name}-{tag}{seed}-{k}", "scene": case, "kicad": kicad})
    with open(out, "w") as f:
        json.dump(cases, f, separators=(",", ":"))
    print(f"{out}: {len(cases)} cases on {len(files)} boards, {sum(len(c['kicad']) for c in cases)} routes"
          + (f", {shoves} of the {drags} drags shoving" if mode == "drag" else "")
          + (f" ({undefined} left out, KiCad's router undefined on them)" if undefined else ""))


def shoved(kicad):
    """Whether KiCad's router shoved anything aside on the board, on the way or in the end"""
    return any(r.get("removed") or any((m.get("node") or {}).get("removed") for m in r["moves"]) for r in kicad)


def main():
    args = sys.argv[1:]
    mode, shoving_only, real = "walkaround", False, False
    while args and args[0].startswith("--"):
        flag = args.pop(0)
        if flag == "--mode":
            mode = args.pop(0)
            if mode not in ("walkaround", "shove", "mix", "drag"):
                sys.exit(f"scenes.py: no mode {mode}")
        elif flag == "--shoving":
            shoving_only = True
        elif flag == "--boards":
            real = True
        else:
            sys.exit(f"scenes.py: no option {flag}")
    if real:
        # scenes.py [--mode MODE] --boards KICAD_ROUTER OUT.json PER_BOARD SEED SCENE.json...
        boards(args[0], args[1], args[4:], int(args[2]), int(args[3]), mode)
        return
    router, out = args[0], args[1]
    count = int(args[2]) if len(args) > 2 else 40
    seed = int(args[3]) if len(args) > 3 else 20261016
    rng = random.Random(seed)
    cases = []
    prefix = "random" if mode == "walkaround" else mode
    n = 0
    undefined = 0
    quiet = 0
    drags = shoves = 0
    while len(cases) < count:
        scene = board(rng, n, mode)
        shoving = 0
        if mode == "drag":
            done, shoving = drag_routes(router, rng, scene, board_area(scene), rng.randint(1, 5))
            kicad = None
            if done is not None:
                scene["routes"], kicad = done
        else:
            kicad = route(router, scene)
        if kicad is None:
            undefined += 1
        elif shoving_only and not (shoving if mode == "drag" else shoved(kicad)):
            # (--shoving: only boards on which something was shoved)
            quiet += 1
        else:
            cases.append({"name": f"{prefix}-{seed}-{n}", "scene": scene, "kicad": kicad})
            drags += len(scene["routes"])
            shoves += shoving
        n += 1
    with open(out, "w") as f:
        json.dump(cases, f, separators=(",", ":"))
    print(f"{out}: {count} boards, {sum(len(c['kicad']) for c in cases)} routes"
          + (f", {shoves} of the {drags} drags shoving" if mode == "drag" else "")
          + (f" ({undefined} more left out, KiCad's router undefined on them)" if undefined else "")
          + (f" ({quiet} more left out, nothing shoved on them)" if quiet else ""))


if __name__ == "__main__":
    main()
