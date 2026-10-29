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

With `--mode cdrag`, the routes are footprints dragged instead, as the router tool drags a footprint with the tracks
on its pads (KiCad's COMPONENT_DRAGGER), on boards with footprints of a few pads in a row or two (now and then a hole
with no plating, now and then a drawing on copper among them), tracks on their pads (out of a pad, some with arcs;
from one of a footprint's pads to another of its own, which the drag moves whole; from one footprint's pad to
another's; some ending inside a pad off its centre) and other nets' tracks and vias near by: each footprint dragged
from its first pad or by it, the pointer taken away (now and then into another net's track, via or pad), and clicked
to keep the drag (now and then with Ctrl); each on the board as the drags before it left it, the footprint's pads
moved as KiCad's commit moves the footprint. With `--boards`, the footprints of real boards.

With `--mode mdrag`, the routes are several tracks dragged together instead, as the router tool drags the tracks
selected (KiCad's MULTI_DRAGGER), on boards like the drag mode's with buses on them (two to five lines of different
nets side by side, a straight run and now and then a turn after it, some ending free, some on a via or a pad): a
segment of each line of a bus (the pointer on one of them, or near), or their last segments (the pointer at one's
end, or near), or segments near each other anywhere, dragged across mostly, now and then into another net's track or
via, and clicked to keep the drag; each on the board as the drags before it left it. With `--boards`, segments near
each other on real boards.

With `--arcs`, the boards have arc tracks too (on their own or out of pads; the shove and drag modes' tracks with
some of their turns rounded), routes start on arcs and go to them, and drags grab arcs by their middles; with
`--rounded`, each route turns its corners in a corner mode of its own (mitred or rounded, at 45 or 90 degrees). A
board on which KiCad's line placer would read an arc as a segment is left out (router.cpp stops there, with exit
status 3, as above).

With `--mode meander`, the routes are length tunings instead, by KiCad's meander placer, on boards with tracks to
tune from pad to pad (some through vias, some with arcs) among others: each started on a track, the pointer taken
along its line, the meanders' amplitude or spacing stepped now and then, most kept; each to a length of its own,
chosen from the length KiCad measures the track's path to be (shorter, about it, longer), and each on the board as the
tunings before it left it. With `--mode dpmeander`, differential pairs' lengths and skews tuned, on boards with
coupled tracks of pairs' nets.

    scenes.py [--mode shove|mix|drag|cdrag|mdrag|diffpair|meander|dpmeander] [--shoving] [--arcs] [--rounded]
        KICAD_ROUTER OUT.json [COUNT [SEED]]
    scenes.py [--mode shove|mix|drag|cdrag|mdrag|diffpair|meander|dpmeander] [--arcs] [--rounded] --boards KICAD_ROUTER
        OUT.json
        ROUTES_PER_BOARD SEED SCENE.json...   (real boards, from board-scene.py)
"""

import json
import math
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


DIRS = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]


def arc_turn(p, d, turn, r):
    """An arc track's mid and end from `p`, going on in direction `d` (one of DIRS) and turning `turn` eighths of a
    turn (positive the way DIRS go round) on a radius of `r`, tangent to the way it came and the way it goes on"""
    u = (DIRS[d][0] / math.hypot(*DIRS[d]), DIRS[d][1] / math.hypot(*DIRS[d]))
    side = 1 if turn > 0 else -1
    c = (p[0] - u[1] * side * r, p[1] + u[0] * side * r)

    def at(a):
        dx, dy = p[0] - c[0], p[1] - c[1]
        return [round(c[0] + dx * math.cos(a) - dy * math.sin(a)), round(c[1] + dx * math.sin(a) + dy * math.cos(a))]

    theta = turn * math.pi / 4
    return at(theta / 2), at(theta)


def polylines(rng, items, size, nets, copper, dense, arcs=False):
    """Tracks to shove: lines of a few segments at 45 and 90 degrees, some from pads of their net, some going on
    through a via on another layer, some locked; and vias on their own. With `arcs`, some of their turns rounded,
    arc tracks tangent to the segments either side."""
    last = copper - 1
    lo, hi = 2 * MM, size - 2 * MM
    dirs = DIRS
    pads = [it for it in items if it["kind"] == "pad" and not it.get("npth")]

    def line(start, net, layer, width, locked):
        p = start
        d = rng.randrange(8)
        for _ in range(rng.randint(1, 4)):
            # (on, or a turn of 45 or 90 degrees)
            turn = rng.choice([0, 1, -1, 2, -2])
            if arcs and turn and rng.random() < 0.5:
                # (the turn an arc from here)
                mid, end = arc_turn(p, d, turn, rng.randint(2, 16) * 125_000)
                if not (lo <= end[0] <= hi and lo <= end[1] <= hi):
                    break
                a = {"kind": "arc", "net": net, "layer": layer, "start": p, "mid": mid, "end": end, "width": width}
                if locked:
                    a["locked"] = True
                items.append(a)
                p = end
            d = (d + turn) % 8
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


def board(rng, n, mode="walkaround", arcs=False, rounded=False):
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
    if mode != "walkaround" or arcs:
        polylines(rng, items, size, nets, copper, dense, arcs)
    if mode == "drag":
        # (more of them, to drag and to drag into)
        polylines(rng, items, size, nets, copper, dense, arcs)
    if arcs:
        arc_tracks(rng, items, size, nets, copper)
    rules = {"clearance": rng.choice([150_000, 200_000, 250_000]), "holeClearance": 250_000, "holeToHole": 250_000,
             "edgeClearance": rng.choice([300_000, 500_000])}
    # (drags are chosen later, each on the board as the drags before it left it)
    scene = {"layers": copper, "rules": rules, "items": items,
             "routes": [] if mode == "drag" else routes(rng, items, copper, (0, 0, size, size), mode=mode, arcs=arcs,
                                                         rounded=rounded)}
    if mode != "walkaround":
        scene["removeItems"] = True
    return scene


def arc_tracks(rng, items, size, nets, copper):
    """Arc tracks on their own, or out of a pad of their net: of an eighth of a turn to three, on radii of a quarter
    of a millimetre to a few, now and then two one after the other"""
    lo, hi = 2 * MM, size - 2 * MM
    pads = [it for it in items if it["kind"] == "pad" and not it.get("npth")]
    for _ in range(rng.randint(1, 6)):
        width = rng.randint(3, 8) * 50_000
        if pads and rng.random() < 0.3:
            pd = rng.choice(pads)
            net, p = pd["net"], pd["pos"]
            layer = rng.randint(pd["layers"][0], pd["layers"][1])
        else:
            net = rng.randint(1, nets)
            p = [rng.randint(lo, hi) // 50_000 * 50_000, rng.randint(lo, hi) // 50_000 * 50_000]
            layer = rng.randint(0, copper - 1)
        d = rng.randrange(8)
        for _ in range(rng.choice([1, 1, 1, 2])):
            turn = rng.choice([1, -1, 2, -2, 3, -3])
            mid, end = arc_turn(p, d, turn, rng.randint(1, 24) * 125_000)
            if not (lo <= end[0] <= hi and lo <= end[1] <= hi):
                break
            a = {"kind": "arc", "net": net, "layer": layer, "start": p, "mid": mid, "end": end, "width": width}
            if rng.random() < 0.05:
                a["locked"] = True
            items.append(a)
            p, d = end, (d + turn) % 8


def route_mode(rng, mode):
    """The mode a route is made in: walk round, now and then mark obstacles (the default); shove mostly; or any"""
    if mode == "shove":
        r = rng.random()
        return "shove" if r < 0.88 else "mark" if r < 0.94 else "walkaround"
    if mode == "mix":
        return rng.choice(["shove", "walkaround", "mark"])
    return "mark" if rng.random() < 0.2 else "walkaround"


def routes(rng, items, copper, area, count=None, mode="walkaround", arcs=False, rounded=False):
    """Random routes from pads of the board in `area` (x0, y0, x1, y1): to a pad of their net mostly, else anywhere.
    With `arcs`, some from an arc track's end, some to one; with `rounded`, each in a corner mode of its own, its
    corners mitered or rounded, at 45 or 90 degrees."""
    out = []
    x0, y0, x1, y1 = area
    last = copper - 1

    def flashed(it, l):
        if "layers" not in it:
            # (an arc track: on its layer)
            return it["layer"] == l
        return it["layers"][0] <= l <= it["layers"][1] and ("flashed" not in it or it["flashed"][l])

    pads = [i for i, it in enumerate(items) if it["kind"] == "pad" and not it.get("npth")
            and any(flashed(it, l) for l in range(copper))]
    holes = [i for i, it in enumerate(items) if it["kind"] == "pad" and it.get("npth")]
    arc_tracks = [i for i, it in enumerate(items) if it["kind"] == "arc"] if arcs else []
    if not pads:
        return out
    for _ in range(rng.randint(1, 4) if count is None else count):
        a = rng.choice(pads)
        # (now and then from a hole with no plating instead, which KiCad's router will not start from)
        unplated = bool(holes) and rng.random() < 0.05
        if unplated:
            a = rng.choice(holes)
        # (now and then from an arc track's end, or a point along it)
        from_arc = bool(arc_tracks) and not unplated and rng.random() < 0.35
        if from_arc:
            a = rng.choice(arc_tracks)
        same = [i for i in pads if i != a and items[i]["net"] == items[a]["net"]]
        same += [i for i in arc_tracks if i != a and items[i]["net"] == items[a]["net"]]
        if from_arc:
            start = items[a][rng.choice(["start", "end", "start", "end", "mid"])]
            layer = items[a]["layer"]
        else:
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
            end = items[b]["pos"] if "pos" in items[b] else items[b][rng.choice(["start", "end"])]
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
            if s == 1 and items[a].get("layers") == [0, last] and rng.random() < 0.15:
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
        if rounded:
            route["cornerMode"] = rng.choice([0, 1, 1, 2, 3, 3])
        out.append(route)
    return out


def drag(rng, items, area, arcs=False):
    """A random drag of one of `items`' tracks or vias, as the router tool's drag (D) or free angle drag (G) starts one
    with the pointer on it, and the pointer's way from there; None if there is nothing to drag. With `arcs`, now and
    then an arc track's, grabbed along it."""
    x0, y0, x1, y1 = area
    tracks = [i for i, it in enumerate(items) if it["kind"] == "track" and it["a"] != it["b"]]
    vias = [i for i, it in enumerate(items) if it["kind"] == "via"]
    arc_tracks = [i for i, it in enumerate(items) if it["kind"] == "arc"] if arcs else []
    if not tracks and not vias and not arc_tracks:
        return None
    if arc_tracks and (not tracks and not vias or rng.random() < 0.3):
        i = rng.choice(arc_tracks)
        grabbed = "arc"
        at = list(items[i]["mid"])
        if rng.random() < 0.5:
            # (along it, a little off it)
            w = items[i]["width"] // 4
            at = [at[0] + rng.randint(-w, w), at[1] + rng.randint(-w, w)]
    elif vias and (not tracks or rng.random() < 0.3):
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
    if grabbed == "arc" and rng.random() < 0.6:
        # (an arc's mid pulled out from its chord or pushed in towards it, as far again or more, or past it)
        (sx, sy), (mx, my), (ex, ey) = items[i]["start"], items[i]["mid"], items[i]["end"]
        t = rng.uniform(-1.6, 1.2)
        end = [int(mx + (mx - (sx + ex) / 2) * t), int(my + (my - (sy + ey) / 2) * t)]
    elif own and rng.random() < 0.2:
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


def drag_routes(router, rng, scene, area, count, arcs=False):
    """`count` drags on the scene's board, each chosen on the board as the drags before it left it (KiCad's router run
    on those to know), and what KiCad's router made of them (None if what it does is undefined); and how many of them
    shoved another net's track or via, on the way or in the end"""
    items = list(scene["items"])
    drags, kicad, shoving = [], [], 0
    for _ in range(count):
        d = drag(rng, items, area, arcs)
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


def footprint_board(rng, n, arcs=False):
    """A board with footprints to drag: each a few pads of one shape in a row or two rows (now and then a hole with no
    plating among them, now and then a drawing on copper of one of their nets), tracks on their pads (out of a pad's
    centre, one segment or a few, some with arcs; from one pad of a footprint to another of its own of the same net,
    which the drag moves whole; from a pad of one footprint to one of another's; some ending inside a pad, off its
    centre), and other nets' tracks and vias near by to drag them into"""
    copper = rng.choice([2, 2, 2, 4])
    last = copper - 1
    size = rng.randint(20, 36) * MM
    items = []
    c = [[0, 0], [size, 0], [size, size], [0, size]]
    for i in range(4):
        items.append({"kind": "edge", "shape": {"segment": [c[i], c[(i + 1) % 4]], "w": 0}})
    nets = rng.randint(2, 6)
    used = []
    footprints = []
    for k in range(rng.randint(2, 5)):
        count = rng.randint(2, 8)
        rows = 2 if count >= 4 and rng.random() < 0.5 else 1
        pitch = rng.randint(24, 50) * 50_000
        span = (count + rows - 1) // rows
        for _ in range(50):
            x = rng.randint(3 * MM, max(3 * MM, size - 3 * MM - span * pitch)) // 50_000 * 50_000
            y = rng.randint(3 * MM, size - 3 * MM - 3 * MM) // 50_000 * 50_000
            if all(abs(x - u) > span * pitch + 2 * MM or abs(y - v) > 5 * MM for u, v in used):
                break
        used.append((x, y))
        layers = rng.choice([[0, 0], [0, 0], [last, last], [0, last], [0, last]])
        through = layers == [0, last]
        ref = f"U{k + 1}"
        template = pad(rng, 1, (0, 0), layers, through)
        row_gap = rng.randint(40, 80) * 50_000
        indices = []
        for p in range(count):
            q = (x + (p % span) * pitch, y + (p // span) * row_gap)
            it = json.loads(json.dumps(template))
            it["pos"] = list(q)
            it["shape"] = moved(template["shape"], q)
            if "hole" in it:
                it["hole"] = moved(template["hole"], q)
            it.pop("npth", None)
            it["net"] = rng.randint(1, nets)
            if through and rng.random() < 0.06:
                it["npth"] = True
                it["net"] = 0
            it["footprint"] = ref
            indices.append(len(items))
            items.append(it)
        if rng.random() < 0.2:
            # (a drawing on copper, of the net of one of its pads: a polygon by the pads)
            net = items[rng.choice(indices)]["net"] or 1
            l = layers[0]
            gx, gy = x - pitch // 2, y - pitch
            w, h = rng.randint(4, 12) * 100_000, rng.randint(2, 6) * 100_000
            items.append({"kind": "graphic", "net": net, "layers": [l, l], "footprint": ref,
                          "shape": {"simple": [[gx, gy], [gx + w, gy], [gx + w, gy + h], [gx, gy + h]]}})
        footprints.append(indices)
    pads = [i for fp in footprints for i in fp if not items[i].get("npth")]
    lo, hi = 2 * MM, size - 2 * MM

    def layer_of(p):
        lp = items[p]["layers"]
        return rng.randint(lp[0], lp[1])

    def line_from(start, net, layer, width, end=None):
        """A track of a few segments at 45 and 90 degrees from `start` (to `end`, if given: two segments, a
        diagonal and a straight one, as the router makes them), its turns now and then rounded by arcs"""
        p = list(start)
        if end is not None:
            dx, dy = end[0] - p[0], end[1] - p[1]
            m = min(abs(dx), abs(dy))
            mid = [p[0] + (m if dx > 0 else -m), p[1] + (m if dy > 0 else -m)]
            for a, b in ((p, mid), (mid, list(end))):
                if a != b:
                    items.append({"kind": "track", "net": net, "layer": layer, "a": a, "b": b, "width": width})
            return
        d = rng.randrange(8)
        for _ in range(rng.randint(1, 4)):
            turn = rng.choice([0, 1, -1, 2, -2])
            if arcs and turn and rng.random() < 0.5:
                mid, e = arc_turn(p, d, turn, rng.randint(2, 16) * 125_000)
                if not (lo <= e[0] <= hi and lo <= e[1] <= hi):
                    break
                items.append({"kind": "arc", "net": net, "layer": layer, "start": p, "mid": mid, "end": e,
                              "width": width})
                p = e
            d = (d + turn) % 8
            step = rng.randint(2, 12) * 250_000
            q = [p[0] + DIRS[d][0] * step, p[1] + DIRS[d][1] * step]
            if not (lo <= q[0] <= hi and lo <= q[1] <= hi):
                break
            items.append({"kind": "track", "net": net, "layer": layer, "a": p, "b": q, "width": width})
            p = q

    def inside(i):
        """A point inside pad `i`, off its centre"""
        w, h = shape_size(items[i]["shape"])
        x, y = items[i]["pos"]
        r = max(min(w, h) // 4, 50_000)
        return [x + rng.choice([-1, 1]) * rng.randint(r // 3, r), y + rng.choice([-1, 1]) * rng.randint(0, r)]

    for _ in range(rng.randint(2, 10)):
        if not pads:
            break
        a = rng.choice(pads)
        net, layer, width = items[a]["net"], layer_of(a), rng.randint(3, 8) * 50_000
        kind = rng.random()
        same = [b for b in pads if b != a and items[b]["net"] == net
                and items[b]["layers"][0] <= layer <= items[b]["layers"][1]]
        own = [b for b in same if items[b].get("footprint") == items[a].get("footprint")]
        if kind < 0.25 and own:
            # (from one pad of a footprint to another of its own: moved whole with it)
            line_from(items[a]["pos"], net, layer, width, end=items[rng.choice(own)]["pos"])
        elif kind < 0.4 and same:
            # (from a pad to one of another footprint's)
            line_from(items[a]["pos"], net, layer, width, end=items[rng.choice(same)]["pos"])
        elif kind < 0.55:
            # (from a pad's centre to inside another of its net, off its centre; or from elsewhere to inside a pad)
            if same and rng.random() < 0.5:
                line_from(items[a]["pos"], net, layer, width, end=inside(rng.choice(same)))
            else:
                start = [rng.randint(lo, hi) // 50_000 * 50_000, rng.randint(lo, hi) // 50_000 * 50_000]
                line_from(start, net, layer, width, end=inside(a))
        else:
            line_from(items[a]["pos"], net, layer, width)
    # other nets' tracks and vias to drag the footprints into, and pads of no footprint
    polylines(rng, items, size, nets, copper, False, arcs)
    for _ in range(rng.randint(0, 4)):
        q = (rng.randint(lo, hi) // 50_000 * 50_000, rng.randint(lo, hi) // 50_000 * 50_000)
        lay = rng.choice([[0, 0], [last, last], [0, last]])
        items.append(pad(rng, rng.randint(1, nets), q, lay, lay == [0, last]))
    rules = {"clearance": rng.choice([150_000, 200_000, 250_000]), "holeClearance": 250_000, "holeToHole": 250_000,
             "edgeClearance": rng.choice([300_000, 500_000])}
    return {"layers": copper, "rules": rules, "items": items, "routes": [], "removeItems": True}


def footprints_of(items):
    """The footprints among `items`: for each (by its reference, in the order their first items come), what the
    router tool drags of it, its pads, then its keepout zones and its drawings on copper, by index"""
    fps = {}
    for i, it in enumerate(items):
        ref = it.get("footprint") or (it.get("keepout") or {}).get("footprint")
        if ref:
            fps.setdefault(ref, {"pads": [], "rest": []})["pads" if it["kind"] == "pad" else "rest"].append(i)
    return {ref: f["pads"] + f["rest"] for ref, f in fps.items() if f["pads"]}


def component_drag(rng, items, area):
    """A random drag of one of the footprints among `items`, as the router tool drags a footprint (its pads and the
    tracks on them, ROUTER_TOOL::InlineDrag): from its first pad (as the move warps the pointer to the footprint's
    anchor) or from a point by it, the pointer taken away by a way of its own (now and then into another net's track,
    via or pad near by, or back), and clicked to keep the drag (now and then with Ctrl, to keep it whatever it
    collides with); None if there is no footprint"""
    x0, y0, x1, y1 = area
    fps = footprints_of(items)
    if not fps:
        return None
    ref = rng.choice(sorted(fps))
    indices = fps[ref]
    first = items[indices[0]]["pos"]
    if rng.random() < 0.6:
        at = list(first)
    else:
        p = items[rng.choice([i for i in indices if items[i]["kind"] == "pad"])]["pos"]
        at = [p[0] + rng.randint(-4, 4) * 50_000, p[1] + rng.randint(-4, 4) * 50_000]
    r = rng.random()
    mode = "shove" if r < 0.4 else "walkaround" if r < 0.75 else "mark"
    route = {"cdrag": {"items": indices, "at": at}, "mode": mode}
    if mode == "mark" and rng.random() < 0.3:
        route["allowViolations"] = True
    nets = {items[i].get("net") for i in indices}
    near = []
    for it in items:
        if it["kind"] not in ("track", "via", "pad") or it.get("net") in nets or it.get("footprint") == ref:
            continue
        p = it["pos"] if "pos" in it else [(it["a"][0] + it["b"][0]) // 2, (it["a"][1] + it["b"][1]) // 2]
        if abs(p[0] - at[0]) + abs(p[1] - at[1]) < 6 * MM:
            near.append(p)
    if near and rng.random() < 0.6:
        p = rng.choice(near)
        over = rng.uniform(0.5, 1.2)
        end = [int(at[0] + (p[0] - at[0]) * over), int(at[1] + (p[1] - at[1]) * over)]
    else:
        span = rng.choice([2, 6, 12, 20])
        end = [at[0] + rng.randint(-span, span) * 250_000, at[1] + rng.randint(-span, span) * 250_000]
    end = [min(max(end[0], x0), x1), min(max(end[1], y0), y1)]
    steps = rng.randint(1, 5)
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
        back = rng.uniform(0.2, 1.0)
        moves.append([int(end[0] + (at[0] - end[0]) * back), int(end[1] + (at[1] - end[1]) * back)])
    if rng.random() < 0.15:
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


def component_drag_routes(router, rng, scene, area, count):
    """`count` footprint drags on the scene's board, each chosen on the board as the drags before it left it, and
    what KiCad's router made of them (None if what it does is undefined); and how many of them were kept"""
    items = list(scene["items"])
    drags, kicad, kept = [], [], 0
    for _ in range(count):
        d = component_drag(rng, items, area)
        if d is None:
            break
        drags.append(d)
        kicad = route(router, dict(scene, routes=drags))
        if kicad is None:
            return None, 0
        r = kicad[-1]
        kept += bool(r.get("fixed") or any(m.get("fixed") for m in r["moves"]))
        for k in reversed(r.get("removed", [])):
            del items[k]
        items += r["added"]
    return (drags, kicad), kept


def cdrag_stats(cases):
    """How the footprints' drags went: kept, refused, and what they dragged with them (tracks moved whole, from one
    of their pads to another; lines whose ends they dragged; arcs among them)"""
    rs = [k for c in cases for k in c["kicad"]]
    kept = sum(bool(k.get("fixed") or any(m.get("fixed") for m in k["moves"])) for k in rs)
    refused = sum(any(m.get("fixed") is False for m in k["moves"]) or k.get("fixed") is False for k in rs)
    whole = fanned = arcs = 0
    for k in rs:
        dragged = [d for m in k["moves"] for d in m.get("dragged", [])]
        whole += any(d.get("kind") in ("track", "arc") for d in dragged)
        fanned += any("points" in d for d in dragged)
        arcs += any(d.get("kind") == "arc" or "arcs" in d for d in dragged)
    return (f"{kept} kept, {refused} refused a click, {whole} moving tracks whole, {fanned} dragging lines' ends, "
            f"{arcs} with arcs")


def buses(rng, items, size, nets, copper):
    """Buses of tracks to drag together: two to five lines of different nets side by side, a pitch apart, each of a
    straight run and now and then a turn of 45 or 90 degrees after it (the turn's corner further along for the lines
    on its outside, so that they stay a pitch apart), some ending free, some on a via or a pad of their net; and their
    indices among the items, by line, each line's segments in order"""
    lo, hi = 3 * MM, size - 3 * MM
    out = []
    for _ in range(rng.randint(1, 3)):
        count = rng.randint(2, 5)
        width = rng.randint(3, 6) * 50_000
        pitch = width + rng.randint(4, 10) * 50_000
        d = rng.randrange(8)
        ux, uy = DIRS[d][0] / math.hypot(*DIRS[d]), DIRS[d][1] / math.hypot(*DIRS[d])
        nx, ny = -uy, ux
        base = [rng.randint(lo, hi) // 50_000 * 50_000, rng.randint(lo, hi) // 50_000 * 50_000]
        run = rng.randint(4, 16) * 250_000
        turn = rng.choice([0, 1, -1, 2, -2])
        tail = rng.randint(2, 10) * 250_000
        layer = rng.randint(0, copper - 1)
        lines = []
        for i in range(count):
            net = rng.randint(1, nets)
            o = i * pitch
            a = [round(base[0] + nx * o), round(base[1] + ny * o)]
            # (the corner along the run: further for a line on the turn's outside)
            t = math.tan(abs(turn) * math.pi / 8)
            side = -1 if turn > 0 else 1
            extra = side * o * t if turn else 0
            b = [round(a[0] + ux * (run + extra)), round(a[1] + uy * (run + extra))]
            pts = [a, b]
            if turn:
                e = (d + turn) % 8
                vx, vy = DIRS[e][0] / math.hypot(*DIRS[e]), DIRS[e][1] / math.hypot(*DIRS[e])
                pts.append([round(b[0] + vx * tail), round(b[1] + vy * tail)])
            if not all(lo <= p[0] <= hi and lo <= p[1] <= hi for p in pts):
                break
            line = []
            for p, q in zip(pts, pts[1:]):
                if p != q:
                    line.append(len(items))
                    items.append({"kind": "track", "net": net, "layer": layer, "a": p, "b": q, "width": width})
            end = rng.random()
            if end < 0.2:
                # (ending on a via of its net)
                diameter = rng.randint(5, 7) * 100_000
                items.append({"kind": "via", "net": net, "pos": pts[-1], "layers": [0, copper - 1], "diameter": diameter,
                              "drill": diameter * 5 // 10 // 50_000 * 50_000})
            elif end < 0.3:
                items.append(pad(rng, net, tuple(pts[0]), [layer, layer], False))
            if line:
                lines.append(line)
        if len(lines) >= 2:
            out.append(lines)
    return out


def mdrag_board(rng, n, arcs=False):
    """A board with buses of tracks to drag together, among the drag mode's tracks and vias"""
    scene = board(rng, n, "drag", arcs)
    size = max(p for it in scene["items"] if it["kind"] == "edge" for p in it["shape"]["segment"][1])
    scene["buses"] = buses(rng, scene["items"], size, max(it.get("net", 1) for it in scene["items"]), scene["layers"])
    return scene


def multi_drag(rng, items, area, lines):
    """A random drag of several tracks together, as the router tool drags the tracks selected (ROUTER_TOOL::InlineDrag:
    the selection's segments): of a bus's lines (`lines`, by index, each its segments) by a segment of each (the
    pointer on one of them, or near) or by their last segments, the pointer at one's end (or near it); else of
    segments near each other; the pointer taken away (now and then into another net's track or via), and clicked to
    keep the drag; None if there is nothing to drag"""
    x0, y0, x1, y1 = area
    tracks = [i for i, it in enumerate(items) if it["kind"] == "track" and it["a"] != it["b"]]
    if lines and rng.random() < 0.85:
        chosen = [l for l in lines if rng.random() < 0.85] or lines
        if len(chosen) < 2:
            chosen = lines
        by_end = rng.random() < 0.4
        k = rng.randrange(min(len(l) for l in chosen))
        picked = [l[-1] if by_end else l[min(k, len(l) - 1)] for l in chosen]
        lead = items[rng.choice(picked)]
        if by_end:
            e = lead["b"]
            r = lead["width"] // 3 if rng.random() < 0.7 else lead["width"] * 2
            at = [e[0] + rng.randint(-r, r), e[1] + rng.randint(-r, r)]
        else:
            t = rng.uniform(0.2, 0.8)
            at = [int(lead["a"][0] + (lead["b"][0] - lead["a"][0]) * t), int(lead["a"][1] + (lead["b"][1] - lead["a"][1]) * t)]
            if rng.random() < 0.3:
                r = lead["width"] * 2
                at = [at[0] + rng.randint(-r, r), at[1] + rng.randint(-r, r)]
    elif len(tracks) >= 2:
        first = rng.choice(tracks)
        a = items[first]["a"]
        near = [i for i in tracks if i != first
                and abs(items[i]["a"][0] - a[0]) + abs(items[i]["a"][1] - a[1]) < 4 * MM]
        if not near:
            return None
        picked = [first] + rng.sample(near, min(len(near), rng.randint(1, 3)))
        lead = items[first]
        at = [(lead["a"][0] + lead["b"][0]) // 2, (lead["a"][1] + lead["b"][1]) // 2]
    else:
        return None
    r = rng.random()
    mode = "shove" if r < 0.45 else "walkaround" if r < 0.8 else "mark"
    route = {"mdrag": {"items": picked, "at": at}, "mode": mode}
    if mode == "mark" and rng.random() < 0.3:
        route["allowViolations"] = True
    if rng.random() < 0.15:
        route["smooth"] = False
    # (across the segments mostly, by up to a few millimetres; now and then into another net's track or via near by)
    (ax, ay), (bx, by) = lead["a"], lead["b"]
    length = math.hypot(bx - ax, by - ay) or 1
    nx, ny = -(by - ay) / length, (bx - ax) / length
    nets = {items[i].get("net") for i in picked}
    near = [it["pos"] if "pos" in it else [(it["a"][0] + it["b"][0]) // 2, (it["a"][1] + it["b"][1]) // 2]
            for it in items if it["kind"] in ("track", "via") and it.get("net") not in nets]
    near = [p for p in near if abs(p[0] - at[0]) + abs(p[1] - at[1]) < 5 * MM]
    if near and rng.random() < 0.3:
        end = list(rng.choice(near))
    else:
        dist = rng.choice([1, 2, 4, 8, 12]) * 250_000 * rng.choice([1, -1])
        along = rng.randint(-4, 4) * 100_000
        end = [int(at[0] + nx * dist + (bx - ax) / length * along), int(at[1] + ny * dist + (by - ay) / length * along)]
    end = [min(max(end[0], x0), x1), min(max(end[1], y0), y1)]
    steps = rng.randint(1, 5)
    moves = []
    for s in range(1, steps + 1):
        t = s / steps
        px = int(at[0] + (end[0] - at[0]) * t)
        py = int(at[1] + (end[1] - at[1]) * t)
        if s < steps:
            px += rng.randint(-2, 2) * 100_000
            py += rng.randint(-2, 2) * 100_000
        moves.append([px, py])
    if rng.random() < 0.2:
        back = rng.uniform(0.2, 1.0)
        moves.append([int(end[0] + (at[0] - end[0]) * back), int(end[1] + (at[1] - end[1]) * back)])
    if rng.random() < 0.15:
        k = rng.randrange(len(moves))
        moves.insert(k, moves[k])
    if rng.random() < 0.1:
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


def multi_drag_routes(router, rng, scene, area, count):
    """`count` drags of several tracks together on the scene's board, each chosen on the board as the drags before it
    left it (KiCad's router run on those to know; a bus's lines only while all of them are there as they were), and
    what KiCad's router made of them (None if what it does is undefined); and how many of them were kept"""
    items = list(scene["items"])
    lines = [l for l in scene.pop("buses", [])]
    drags, kicad, kept = [], [], 0
    for _ in range(count):
        d = multi_drag(rng, items, area, lines[0] if lines else None)
        if d is None:
            break
        drags.append(d)
        kicad = route(router, dict(scene, routes=drags))
        if kicad is None:
            return None, 0
        r = kicad[-1]
        kept += bool(r.get("fixed") or any(m.get("fixed") for m in r["moves"]))
        removed = r.get("removed", [])
        # (a bus with a track taken off or moved is no bus any more; the indices of those after the ones taken off)
        lines = [[[i - sum(1 for k in removed if k < i) for i in l] for l in b] for b in lines
                 if not any(i in removed for l in b for i in l)]
        rng.shuffle(lines)
        for k in reversed(removed):
            del items[k]
        items += r["added"]
    return (drags, kicad), kept


def mdrag_stats(cases):
    """How the drags of several tracks went: kept, refused, and how many lines they dragged"""
    rs = [k for c in cases for k in c["kicad"]]
    kept = sum(bool(k.get("fixed") or any(m.get("fixed") for m in k["moves"])) for k in rs)
    started = sum(k["started"] for k in rs)
    several = sum(any(len(m.get("dragged", [])) >= 1 for m in k["moves"]) for k in rs)
    moved = sum(bool(k.get("removed")) for k in rs)
    return f"{started} started, {kept} kept, {moved} moving tracks, {several} dragging other lines' ends by the first's"


# differential pairs' nets as KiCad recognises them (BOARD::MatchDpSuffix: a last P, N, + or -, digits and
# underscores after it aside), and nets that are not pairs (one named as a pair's, its partner missing)
PAIR_NAMES = [("USB_D+", "USB_D-"), ("USB_P", "USB_N"), ("LVDS0_P", "LVDS0_N"), ("CLK_P1", "CLK_N1"),
              ("TX_P_2", "TX_N_2"), ("D+", "D-"), ("ETH_RX+", "ETH_RX-"), ("HDMI_D0_P", "HDMI_D0_N")]
SINGLE_NAMES = ["GND", "VCC", "SIG1", "RESET", "RX_P", "SPARE_N"]


def pad_pair(rng, nets, pos, direction, layers, through):
    """A pad of each of a pair's nets (`nets`: positive, negative), side by side as a pair's pads are, the same shape:
    the negative one `direction` (a unit 45 degree step) times the pitch from the positive one"""
    x, y = pos
    p = pad(rng, nets[0], (x, y), layers, through)
    p.pop("npth", None)
    p["net"] = nets[0]
    shape = p["shape"]
    box = shape_size(shape)
    pitch = (max(box) + rng.randint(3, 12) * 50_000) // 50_000 * 50_000
    d = (direction[0] * pitch, direction[1] * pitch)
    n = json.loads(json.dumps(p))
    n["net"] = nets[1]
    n["pos"] = [x + d[0], y + d[1]]
    n["shape"] = moved(shape, d)
    if "hole" in n:
        n["hole"] = moved(n["hole"], d)
    if rng.random() < 0.5:
        p, n = n, p
    return [p, n], pitch


def shape_size(shape):
    """A pad shape's width and height"""
    if "rect" in shape:
        return shape["size"]
    if "circle" in shape:
        return [2 * shape["r"]] * 2
    if "segment" in shape:
        (ax, ay), (bx, by) = shape["segment"]
        return [abs(bx - ax) + shape["w"], abs(by - ay) + shape["w"]]
    xs = [q[0] for q in shape["simple"]]
    ys = [q[1] for q in shape["simple"]]
    return [max(xs) - min(xs), max(ys) - min(ys)]


def moved(shape, d):
    """A pad shape moved by `d`"""
    s = json.loads(json.dumps(shape))
    if "rect" in s:
        s["rect"] = [s["rect"][0] + d[0], s["rect"][1] + d[1]]
    elif "circle" in s:
        s["circle"] = [s["circle"][0] + d[0], s["circle"][1] + d[1]]
    elif "segment" in s:
        s["segment"] = [[q[0] + d[0], q[1] + d[1]] for q in s["segment"]]
    else:
        s["simple"] = [[q[0] + d[0], q[1] + d[1]] for q in s["simple"]]
    return s


def dp_complement(name):
    """The name of the net a net of this name is coupled with, as KiCad's BOARD::MatchDpSuffix makes it (None if it
    names no pair's net)"""
    for count, ch in enumerate(reversed(name), 1):
        if ch.isdigit() or ch == "_":
            continue
        other = {"+": "-", "-": "+", "N": "P", "P": "N"}.get(ch)
        return None if other is None else name[:len(name) - count] + other + name[len(name) - count + 1:]
    return None


def pair_of(scene, net):
    """The nets of the pair `net` is one of (just `net`, if it is none's)"""
    names = scene["netNames"]
    name = names.get(str(net))
    other = dp_complement(name or "")
    coupled = [int(k) for k, v in names.items() if v == other]
    return {net, coupled[0]} if coupled else {net}


def diffpair_board(rng, n, arcs=False):
    """A board with differential pairs to route: pads of each pair's nets in pairs, at each end of where the pair is to
    go (now and then a third end), some with a pair of tracks out of them that end short, now and then a pair of vias
    of its nets; pads of other nets, and tracks of a few segments and vias in the way, as the shove mode's"""
    copper = rng.choice([2, 2, 2, 4])
    last = copper - 1
    dense = rng.random() < 0.25
    size = rng.randint(14, 20) * MM if dense else rng.randint(20, 32) * MM
    items = []
    c = [[0, 0], [size, 0], [size, size], [0, size]]
    for i in range(4):
        items.append({"kind": "edge", "shape": {"segment": [c[i], c[(i + 1) % 4]], "w": 0}})
    names = {}
    pairs = []
    for p, q in rng.sample(PAIR_NAMES, rng.randint(1, 3)):
        names[len(names) + 1] = p
        names[len(names) + 1] = q
        pairs.append((len(names) - 1, len(names)))
    for name in rng.sample(SINGLE_NAMES, rng.randint(2, 4)):
        names[len(names) + 1] = name
    nets = len(names)
    lo, hi = 2 * MM, size - 2 * MM
    dirs = [(1, 0), (0, 1), (1, 1), (1, -1)]
    used = []

    def place(gap):
        for _ in range(50):
            x = rng.randint(lo, hi) // 50_000 * 50_000
            y = rng.randint(lo, hi) // 50_000 * 50_000
            if all(abs(x - u) > gap or abs(y - v) > gap for u, v in used):
                break
        used.append((x, y))
        return x, y

    singles = list(range(2 * len(pairs) + 1, nets + 1))
    crossings = []
    for pair in pairs:
        ends = []
        for _ in range(rng.choice([2, 2, 2, 3])):
            layers = rng.choice([[0, 0], [0, 0], [last, last], [0, last]])
            through = layers == [0, last]
            direction = rng.choice(dirs)
            twin, pitch = pad_pair(rng, pair, place(3 * MM), direction, layers, through)
            items += twin
            ends.append((twin[0]["pos"], layers))
            if rng.random() < 0.3:
                # (a pair of tracks out of them, side by side, ending short of anything)
                out = (-direction[1], direction[0]) if rng.random() < 0.5 else (direction[1], -direction[0])
                if rng.random() < 0.5:
                    out = (-out[0], -out[1])
                length = rng.randint(2, 8) * 250_000
                width = rng.randint(2, 5) * 50_000
                layer = rng.randint(layers[0], layers[1])
                for t in twin:
                    a = t["pos"]
                    b = [a[0] + out[0] * length, a[1] + out[1] * length]
                    if lo <= b[0] <= hi and lo <= b[1] <= hi:
                        items.append({"kind": "track", "net": t["net"], "layer": layer, "a": a, "b": b, "width": width})
        # (tracks of other nets across the way from one end to the next, to walk round or shove)
        for (a, la), (b, lb) in zip(ends, ends[1:]):
            for _ in range(rng.choice([0, 1, 1, 2, 3])):
                t = rng.uniform(0.25, 0.75)
                m = [int(a[0] + (b[0] - a[0]) * t), int(a[1] + (b[1] - a[1]) * t)]
                d = rng.choice(dirs)
                half = rng.randint(4, 12) * 250_000
                crossings.append({"kind": "track", "net": rng.choice(singles + [k for p in pairs if p != pair for k in p]),
                                  "layer": rng.choice([la[0], la[1], lb[0], lb[1]]),
                                  "a": [m[0] - d[0] * half, m[1] - d[1] * half], "b": [m[0] + d[0] * half, m[1] + d[1] * half],
                                  "width": rng.randint(2, 6) * 50_000})
                if rng.random() < 0.08:
                    crossings[-1]["locked"] = True
        if rng.random() < 0.3:
            # (a pair of vias of its nets)
            diameter = rng.randint(5, 8) * 100_000
            drill = diameter * rng.randint(4, 6) // 10 // 50_000 * 50_000
            x, y = place(3 * MM)
            dx, dy = rng.choice(dirs)
            pitch = diameter + rng.randint(3, 8) * 50_000
            for k, net in enumerate(pair):
                items.append({"kind": "via", "net": net, "pos": [x + k * dx * pitch, y + k * dy * pitch],
                              "layers": [0, last], "diameter": diameter, "drill": drill})
    items += crossings
    for _ in range(rng.randint(3, 12 if dense else 8)):
        layers = rng.choice([[0, 0], [last, last], [0, last]])
        items.append(pad(rng, rng.choice(singles), place(1_500_000), layers, layers == [0, last]))
    polylines(rng, items, size, nets, copper, dense, arcs)
    if arcs:
        arc_tracks(rng, items, size, nets, copper)
    rules = {"clearance": rng.choice([100_000, 150_000, 200_000]), "holeClearance": 250_000, "holeToHole": 250_000,
             "edgeClearance": rng.choice([300_000, 500_000])}
    return {"layers": copper, "rules": rules, "items": items, "netNames": {str(k): v for k, v in names.items()},
            "routes": [], "removeItems": True}


def diffpair_route(rng, scene, items, area):
    """A random differential pair route, as the router tool's Route Differential Pair (6) routes one: started on a pad,
    via or track end of a pair's net (now and then on another net's, or on nothing, which KiCad refuses), the pointer
    taken to another pair of its pads (its last move and the click on one of them), now and then not; vias placed,
    parts fixed, undo, postures flipped on the way. On the board as the routes before it left it."""
    x0, y0, x1, y1 = area
    copper = scene["layers"]
    last = copper - 1
    names = {int(k): v for k, v in scene["netNames"].items()}
    pair_nets = {k for k in names if len(pair_of(scene, k)) == 2}

    def dangling(i):
        # (a track end that joins nothing: no other track, pad or via of its net there)
        t = items[i]
        ends = []
        for e in (t["a"], t["b"]):
            joined = any(j != i and it.get("net") == t["net"] and
                         (e in (it.get("a"), it.get("b")) or it.get("pos") == e) for j, it in enumerate(items))
            if not joined:
                ends.append(e)
        return ends

    starts = [i for i, it in enumerate(items) if it["kind"] in ("pad", "via") and it.get("net") in pair_nets]
    stubs = [i for i, it in enumerate(items) if it["kind"] == "track" and it.get("net") in pair_nets and dangling(i)]
    others = [i for i, it in enumerate(items) if it["kind"] == "pad" and it.get("net") not in pair_nets]
    r = rng.random()
    if stubs and r < 0.25:
        a = rng.choice(stubs)
        start = rng.choice(dangling(a))
    elif others and r < 0.33:
        a = rng.choice(others)
        start = items[a]["pos"]
    elif r < 0.36:
        a, start = -1, [rng.randint(x0 + MM, x1 - MM), rng.randint(y0 + MM, y1 - MM)]
    else:
        a = rng.choice(starts)
        start = items[a]["pos"]
    it = items[a] if a >= 0 else {}
    lrange = it.get("layers") or ([it["layer"]] * 2 if "layer" in it else [0, last])
    layer = rng.randint(lrange[0], lrange[1])
    # (on a real board, the pair's gap no less than its nets' clearance)
    rules = scene["rules"]
    clearance = max([rules.get("clearance", rules.get("minClearance", 0))] + list(rules.get("netClearance", {}).values()))
    route = {"diffPair": True, "start": start, "startItem": a, "layer": layer,
             "dpWidth": rng.randint(2, 5) * 50_000, "dpGap": clearance + rng.randint(0, 4) * 50_000}
    m = rng.random()
    route["mode"] = "shove" if m < 0.4 else "walkaround" if m < 0.8 else "mark"
    if route["mode"] == "walkaround":
        del route["mode"]
    if rng.random() < 0.3:
        route["dpViaGap"] = clearance + rng.randint(0, 6) * 50_000
    if rng.random() < 0.05:
        # (a board minimum clearance over the pair's gap, which KiCad's router refuses to start)
        route["minClearance"] = route["dpGap"] + 50_000
    if rng.random() < 0.5:
        route["viaDiameter"] = rng.randint(5, 8) * 100_000
        route["viaDrill"] = route["viaDiameter"] * rng.randint(4, 6) // 10 // 50_000 * 50_000
    if rng.random() < 0.1:
        route["fixAll"] = False
    if route.get("mode") == "mark" and rng.random() < 0.3:
        route["allowViolations"] = True
    # where to: a pad or via of the pair elsewhere (of either of its nets), or anywhere
    coupled = pair_of(scene, it.get("net")) if it.get("net") in pair_nets else None
    targets = [i for i, t in enumerate(items) if coupled and t.get("net") in coupled and t["kind"] in ("pad", "via")
               and i != a and (t.get("pos") or [0, 0]) != start
               and abs(t["pos"][0] - start[0]) + abs(t["pos"][1] - start[1]) > 2 * MM]
    targets += [i for i in stubs if coupled and items[i]["net"] in coupled and i != a]
    b = None
    if targets and rng.random() < 0.8:
        b = rng.choice(targets)
        t = items[b]
        end = t["pos"] if "pos" in t else rng.choice(dangling(b))
    else:
        end = [rng.randint(x0 + MM, x1 - MM), rng.randint(y0 + MM, y1 - MM)]
    steps = rng.randint(2, 6)
    points = []
    for s in range(1, steps + 1):
        t = s / steps
        px = int(start[0] + (end[0] - start[0]) * t)
        py = int(start[1] + (end[1] - start[1]) * t)
        if s < steps:
            px += rng.randint(-3, 3) * 300_000
            py += rng.randint(-3, 3) * 300_000
        points.append([px, py])
    events = {}
    if steps > 1 and rng.random() < 0.3:
        events[rng.randint(1, steps - 1)] = "via"
    for kind, chance in (("fix", 0.25), ("undo", 0.1), ("posture", 0.15), ("layer", 0.08)):
        if steps > 1 and rng.random() < chance:
            events.setdefault(rng.randint(1, steps - 1), kind)
    current = layer
    moves = []
    for s, p in enumerate(points, 1):
        # (the last move with the item under the pointer, the pad or via it goes to)
        moves.append({"move": p, "endItem": b} if s == steps and b is not None else {"move": p})
        event = events.get(s)
        if event == "via":
            target = rng.choice([l for l in range(copper) if l != current])
            moves += [{"pair": [current, target]}, {"via": "on"}, {"move": p}]
            if rng.random() < 0.3:
                # (the sizes given again with the vias placed, as the router tool gives them when they change)
                moves += [{"pair": [current, target]}, {"move": p}]
            moves += [{"fix": p, "endItem": -1}, {"layer": target}, {"move": p}]
            current = target
        elif event == "fix":
            moves += [{"fix": p, "endItem": -1}, {"move": p}]
        elif event == "undo":
            moves += [{"fix": p, "endItem": -1}, {"undo": True}, {"move": p}]
        elif event == "posture":
            moves += [{"posture": True}, {"move": p}]
        elif event == "layer":
            # (KiCad's router goes on on another layer only from vias)
            current = rng.choice([l for l in range(copper) if l != current])
            moves += [{"layer": current}, {"move": p}]
    route["moves"] = moves
    if b is not None:
        route["endItem"] = b
    if rng.random() < 0.85:
        route["fix"] = points[-1]
        if rng.random() < 0.1:
            route["forceFinish"] = True
    return route


def diffpair_routes(router, rng, scene, area, count):
    """`count` differential pair routes on the scene's board, each chosen on the board as the routes before it left it
    (KiCad's router run on those to know: a pair fixed short can be gone on from), and what KiCad's router made of
    them (None if what it does is undefined); and how many shoved another net's track or via"""
    items = list(scene["items"])
    routes, kicad, shoving = [], [], 0
    for _ in range(count):
        d = diffpair_route(rng, scene, items, area)
        routes.append(d)
        kicad = route(router, dict(scene, routes=routes))
        if kicad is None:
            return None, 0
        r = kicad[-1]
        own = pair_of(scene, items[d["startItem"]].get("net")) if d["startItem"] >= 0 else set()
        removed = set(r.get("removed", []))
        for m in r["moves"]:
            removed |= set((m.get("node") or {}).get("removed", []))
        if any(items[k].get("net") not in own for k in removed):
            shoving += 1
        for k in reversed(r.get("removed", [])):
            del items[k]
        items += r["added"]
    return (routes, kicad), shoving


def stackup_heights(rng, copper):
    """The board's thickness between each two of its copper layers (BOARD_STACKUP::GetLayerDistance's, which a length
    tuning counts for a via): copper layers at random depths through a board of 0.8 to 2.4 mm, now and then none
    given (KiCad then counts nothing for vias)"""
    if rng.random() < 0.15:
        return []
    total = rng.randint(16, 48) * 50_000
    cuts = sorted(rng.sample(range(1, total // 10_000), copper - 2)) if copper > 2 else []
    z = [0] + [c * 10_000 for c in cuts] + [total]
    return [[abs(a - b) for b in z] for a in z]


def tunable_lines(rng, items, size, nets, copper, arcs=False):
    """Tracks to tune: lines of a few long segments at 45 and 90 degrees from a pad of their net to another (now and
    then from or to nowhere), some through a via to another layer and on, now and then through a pad in line; with
    `arcs`, some of their turns rounded"""
    last = copper - 1
    lo, hi = 2 * MM, size - 2 * MM
    for _ in range(rng.randint(1, 4)):
        net = rng.randint(1, nets)
        width = rng.randint(2, 6) * 50_000
        layer = rng.randint(0, last)
        p = [rng.randint(lo, hi) // 50_000 * 50_000, rng.randint(lo, hi) // 50_000 * 50_000]

        def end_pad(at, layer):
            through = rng.random() < 0.3
            pd = pad(rng, net, at, [0, last] if through else [layer, layer], through)
            pd.pop("npth", None)
            pd["net"] = net
            items.append(pd)

        if rng.random() < 0.8:
            end_pad(p, layer)
        d = rng.randrange(8)
        for k in range(rng.randint(1, 5)):
            turn = 0 if k == 0 else rng.choice([0, 1, -1, 2, -2])
            if arcs and turn and rng.random() < 0.5:
                mid, end = arc_turn(p, d, turn, rng.randint(2, 16) * 125_000)
                if not (lo <= end[0] <= hi and lo <= end[1] <= hi):
                    break
                items.append({"kind": "arc", "net": net, "layer": layer, "start": p, "mid": mid, "end": end,
                              "width": width})
                p = end
            d = (d + turn) % 8
            step = rng.randint(4, 40) * 250_000
            q = [p[0] + DIRS[d][0] * step, p[1] + DIRS[d][1] * step]
            if not (lo <= q[0] <= hi and lo <= q[1] <= hi):
                break
            items.append({"kind": "track", "net": net, "layer": layer, "a": p, "b": q, "width": width})
            p = q
            r = rng.random()
            if r < 0.15 and copper > 1:
                # (through a via, on on another layer)
                diameter = rng.randint(5, 8) * 100_000
                items.append({"kind": "via", "net": net, "pos": p, "layers": [0, last], "diameter": diameter,
                              "drill": diameter * rng.randint(4, 6) // 10 // 50_000 * 50_000})
                layer = rng.choice([l for l in range(copper) if l != layer])
            elif r < 0.2:
                # (through a pad in line)
                end_pad(p, layer)
        if rng.random() < 0.7:
            end_pad(p, layer)


def meander_board(rng, n, arcs=False):
    """A board with tracks to tune (tunable_lines), and pads, tracks and vias of other nets about them, as the drag
    mode's, that the meanders must keep clear of"""
    copper = rng.choice([2, 2, 2, 4])
    last = copper - 1
    dense = rng.random() < 0.25
    size = rng.randint(14, 20) * MM if dense else rng.randint(20, 40) * MM
    items = []
    c = [[0, 0], [size, 0], [size, size], [0, size]]
    for i in range(4):
        items.append({"kind": "edge", "shape": {"segment": [c[i], c[(i + 1) % 4]], "w": 0}})
    nets = rng.randint(2, 6)
    tunable_lines(rng, items, size, nets, copper, arcs)
    used = []
    for _ in range(rng.randint(2, 12 if dense else 8)):
        x = rng.randint(2 * MM, size - 2 * MM) // 50_000 * 50_000
        y = rng.randint(2 * MM, size - 2 * MM) // 50_000 * 50_000
        layers = rng.choice([[0, 0], [last, last], [0, last]])
        items.append(pad(rng, rng.randint(1, nets), (x, y), layers, layers == [0, last]))
    polylines(rng, items, size, nets, copper, dense, arcs)
    if arcs:
        arc_tracks(rng, items, size, nets, copper)
    rules = {"clearance": rng.choice([100_000, 150_000, 200_000, 250_000]), "holeClearance": 250_000,
             "holeToHole": 250_000, "edgeClearance": rng.choice([300_000, 500_000])}
    return {"layers": copper, "rules": rules, "items": items, "stackupHeights": stackup_heights(rng, copper),
            "routes": [], "removeItems": True}


def meander_settings(rng, length):
    """Random tuning settings (MEANDER_SETTINGS), for a path `length` long: a target shorter than it (too long
    already), about it, longer by a little or a lot (more than the meanders can make: too short), or none; its
    tolerance KiCad's default or its own; the meanders' amplitudes, spacing, step, corners, sides"""
    s = {}
    r = rng.random()
    if r < 0.9 and length:
        factor = rng.choice([rng.uniform(0.7, 0.98), rng.uniform(0.99, 1.02), rng.uniform(1.02, 1.3),
                             rng.uniform(1.3, 2.0), rng.uniform(2.0, 4.0)])
        s["targetLength"] = int(length * factor)
        if rng.random() < 0.3:
            tol = rng.randint(1, 40) * 50_000
            s["targetMin"] = s["targetLength"] - tol
            s["targetMax"] = s["targetLength"] + rng.choice([tol, rng.randint(0, 40) * 50_000])
    if rng.random() < 0.8:
        s["minAmplitude"] = rng.randint(1, 12) * 50_000
        s["maxAmplitude"] = s["minAmplitude"] + rng.randint(0, 50) * 50_000
    if rng.random() < 0.8:
        s["spacing"] = rng.randint(4, 40) * 50_000
    if rng.random() < 0.3:
        s["step"] = rng.choice([25_000, 50_000, 100_000, 200_000])
    if rng.random() < 0.35:
        s["cornerStyle"] = "chamfer"
    if rng.random() < 0.5:
        s["cornerRadius"] = rng.choice([0, 10, 25, 50, 80, 100, rng.randint(0, 100)])
    if rng.random() < 0.2:
        s["singleSided"] = True
    s["initialSide"] = rng.choice([-1, -1, 0, 0, 1])
    # (the tuning pattern generator keeps the points the tuned part is cut at; now and then not)
    s["keepEndpoints"] = rng.random() < 0.8
    return s


def meander_route(rng, scene, items, area, length_of):
    """A random length tuning, as the tuning pattern generator starts one: on a track's segment or arc (now and then on
    a via, a pad or nothing, which KiCad refuses), from a point along it, the pointer then taken along its line (to a
    point of a segment of it, a little off it on one side or the other, to its end, or past it), now and then back,
    the meanders' amplitude or spacing stepped on the way; most fixed. `length_of` gives the length KiCad measures
    along the path from the track (None: a track it will not tune)."""
    x0, y0, x1, y1 = area
    tracks = [i for i, it in enumerate(items) if it["kind"] in ("track", "arc")]
    r = rng.random()
    route = {}
    if not tracks or r < 0.04:
        others = [i for i, it in enumerate(items) if it["kind"] in ("via", "pad")]
        i = rng.choice(others) if others and rng.random() < 0.7 else -1
        at = items[i]["pos"] if i >= 0 else [rng.randint(x0, x1), rng.randint(y0, y1)]
        route["tune"] = {"item": i, "at": at, "layer": 0}
        route["moves"] = [[at[0] + MM, at[1]]]
        return route
    # (mostly the long ones, which have room to meander)
    weights = []
    for i in tracks:
        it = items[i]
        a, b = (it["a"], it["b"]) if it["kind"] == "track" else (it["start"], it["end"])
        weights.append(1 + math.hypot(b[0] - a[0], b[1] - a[1]) / MM)
    i = rng.choices(tracks, weights)[0]
    it = items[i]
    if it["kind"] == "arc":
        a, b = it["start"], it["end"]
        at = list(it["mid"]) if rng.random() < 0.5 else list(rng.choice([a, b]))
    else:
        a, b = it["a"], it["b"]
        t = rng.choice([0.0, 1.0, rng.uniform(0, 1), rng.uniform(0, 1)])
        at = [int(a[0] + (b[0] - a[0]) * t), int(a[1] + (b[1] - a[1]) * t)]
    if rng.random() < 0.3:
        w = it["width"]
        at = [at[0] + rng.randint(-w, w), at[1] + rng.randint(-w, w)]
    layer = it["layer"] if rng.random() < 0.95 else rng.randint(0, scene["layers"] - 1)
    route["tune"] = {"item": i, "at": at, "layer": layer}
    route["meander"] = meander_settings(rng, length_of(route))
    # the pointer along the line: to points of the net's tracks on its layer (its line's, mostly), a little to one
    # side or the other, now and then past them
    net = it["net"]
    own = [t for t in items if t["kind"] in ("track", "arc") and t["net"] == net and t["layer"] == it["layer"]]
    moves = []
    for _ in range(rng.choice([1, 1, 1, 2, 2, 3, 4])):
        r = rng.random()
        if r < 0.1:
            # (where it started: the placer does nothing)
            moves.append(list(at))
            continue
        t = rng.choice(own)
        p, q = (t["a"], t["b"]) if t["kind"] == "track" else (t["start"], t["end"])
        f = rng.choice([0.0, 1.0, rng.uniform(0, 1), rng.uniform(0, 1), rng.uniform(-0.3, 1.3)])
        e = [int(p[0] + (q[0] - p[0]) * f), int(p[1] + (q[1] - p[1]) * f)]
        if rng.random() < 0.6:
            off = rng.randint(-8, 8) * 125_000
            n = math.hypot(q[0] - p[0], q[1] - p[1]) or 1
            e = [int(e[0] - (q[1] - p[1]) / n * off), int(e[1] + (q[0] - p[0]) / n * off)]
        moves.append([min(max(e[0], x0), x1), min(max(e[1], y0), y1)])
        if rng.random() < 0.12:
            moves.append({rng.choice(["amplitude", "spacing"]): rng.choice([1, -1, 1, -1, 2])})
            moves.append(moves[-2])
    if rng.random() < 0.08:
        k = rng.randrange(len(moves))
        moves.insert(k + 1, {"fix": moves[k] if isinstance(moves[k], list) else at})
    route["moves"] = moves
    if rng.random() < 0.85:
        route["fix"] = next(m for m in reversed(moves) if isinstance(m, list))
    return route


def meander_routes(router, rng, scene, area, count):
    """`count` length tunings on the scene's board, each chosen on the board as the tunings before it left it (KiCad's
    router run on those to know: a track tuned can be tuned again), and what KiCad's router made of them (None if
    what it does is undefined); and how many were fixed"""
    items = list(scene["items"])
    routes, kicad, tuned = [], [], 0
    for _ in range(count):
        def length_of(tuning):
            # (KiCad's own measure of the path, from a tuning that starts and goes nowhere)
            probe = dict(tuning, moves=[])
            probe.pop("fix", None)
            k = route(router, dict(scene, items=items, routes=[probe]))
            return k[0].get("startLength") if k else None

        d = meander_route(rng, scene, items, area, length_of)
        routes.append(d)
        kicad = route(router, dict(scene, routes=routes))
        if kicad is None:
            return None, 0
        r = kicad[-1]
        if r.get("fixed") or any(m.get("fixed") for m in r["moves"]):
            tuned += 1
        for k in reversed(r.get("removed", [])):
            del items[k]
        items += r["added"]
    return (routes, kicad), tuned


def coupled_lines(rng, items, size, pair, copper, arcs=False):
    """A differential pair's tracks to tune: the positive net's line of a few long segments at 45 and 90 degrees, the
    negative's alongside it the pair's gap apart (its corners where the two lines' offsets meet), now and then from
    and to a pair of pads of their nets; with `arcs`, some turns arcs about one centre. Which line is on which side,
    and which is the inner one round a turn, at random."""
    last = copper - 1
    lo, hi = 2 * MM, size - 2 * MM
    net_p, net_n = pair if rng.random() < 0.5 else (pair[1], pair[0])
    width = rng.randint(2, 5) * 50_000
    gap = rng.randint(2, 8) * 50_000
    s = gap + width
    layer = rng.randint(0, last)
    side = rng.choice([1, -1])
    p = [rng.randint(lo, hi) // 50_000 * 50_000, rng.randint(lo, hi) // 50_000 * 50_000]
    d = rng.randrange(8)

    def unit(d):
        n = math.hypot(*DIRS[d])
        return DIRS[d][0] / n, DIRS[d][1] / n

    def normal(d):
        ux, uy = unit(d)
        return -uy * side, ux * side

    # the positive line: its points, and its segments' directions
    pts = [p]
    dirs = []
    for k in range(rng.randint(1, 4)):
        turn = 0 if k == 0 else rng.choice([1, -1, 2, -2])
        nd = (d + turn) % 8
        step = rng.randint(8, 40) * 250_000
        q = [p[0] + DIRS[nd][0] * step, p[1] + DIRS[nd][1] * step]
        if not (lo <= q[0] <= hi and lo <= q[1] <= hi):
            break
        pts.append(q)
        dirs.append(nd)
        d, p = nd, q
    if len(pts) < 2:
        return

    def off(i):
        # (the negative line's point for the positive's i-th: its offset, mitred at a corner)
        if i == 0:
            nx, ny = normal(dirs[0])
            return [round(pts[0][0] + nx * s), round(pts[0][1] + ny * s)]
        if i == len(pts) - 1:
            nx, ny = normal(dirs[-1])
            return [round(pts[-1][0] + nx * s), round(pts[-1][1] + ny * s)]
        (ax, ay), (bx, by) = normal(dirs[i - 1]), normal(dirs[i])
        k = 1 + ax * bx + ay * by
        return [round(pts[i][0] + s * (ax + bx) / k), round(pts[i][1] + s * (ay + by) / k)]

    npts = [off(i) for i in range(len(pts))]
    # (now and then a right-angled corner of the pair rounded: an arc of each line about one centre)
    rounded = None
    corners = [i for i in range(1, len(pts) - 1) if (dirs[i] - dirs[i - 1]) % 8 in (2, 6)]
    if arcs and corners and rng.random() < 0.6:
        i = rng.choice(corners)
        shortest = min(math.dist(pts[i - 1], pts[i]), math.dist(pts[i], pts[i + 1]),
                       math.dist(npts[i - 1], npts[i]), math.dist(npts[i], npts[i + 1]))
        r = rng.uniform(s + width, max(s + width, shortest / 2 - s))
        if r + s < shortest / 2:
            rounded = (i, r)
    for line, net, base in ((pts, net_p, True), (npts, net_n, False)):
        cut = {}
        if rounded:
            i, r = rounded
            u0, u1 = unit(dirs[i - 1]), unit(dirs[i])
            w = (u1[0] - u0[0], u1[1] - u0[1])
            c = line[i]
            # (the negative line's radius such that its arc has the positive's centre)
            rl = r if base else r - ((c[0] - pts[i][0]) * w[0] + (c[1] - pts[i][1]) * w[1]) / 2
            a = [round(c[0] - u0[0] * rl), round(c[1] - u0[1] * rl)]
            b = [round(c[0] + u1[0] * rl), round(c[1] + u1[1] * rl)]
            centre = (c[0] + w[0] * rl, c[1] + w[1] * rl)
            mid = [round(centre[0] - w[0] * rl / 2 ** 0.5), round(centre[1] - w[1] * rl / 2 ** 0.5)]
            cut = {i: (a, b)}
            items.append({"kind": "arc", "net": net, "layer": layer, "start": a, "mid": mid, "end": b,
                          "width": width})
        for j in range(len(line) - 1):
            a = cut[j][1] if j in cut else line[j]
            b = cut[j + 1][0] if j + 1 in cut else line[j + 1]
            items.append({"kind": "track", "net": net, "layer": layer, "a": a, "b": b, "width": width})
    if rng.random() < 0.6:
        # (a pad of each net at each end of the pair, the same shape)
        for line, net in ((pts, net_p), (npts, net_n)):
            for e in (line[0], line[-1]):
                # (no wider than keeps it off the other line)
                w = width + 50_000 * rng.randint(0, max(0, (gap - 150_000) // 50_000))
                items.append({"kind": "pad", "net": net, "layers": [layer, layer], "pos": e,
                              "shape": {"rect": [e[0] - w // 2, e[1] - w // 2], "size": [w, w]}})


def dpmeander_board(rng, n, arcs=False):
    """A board with differential pairs to tune (coupled_lines), named as KiCad recognises pairs' nets, with pads,
    tracks and vias of other nets about them"""
    copper = rng.choice([2, 2, 2, 4])
    last = copper - 1
    dense = rng.random() < 0.25
    size = rng.randint(14, 20) * MM if dense else rng.randint(20, 40) * MM
    items = []
    c = [[0, 0], [size, 0], [size, size], [0, size]]
    for i in range(4):
        items.append({"kind": "edge", "shape": {"segment": [c[i], c[(i + 1) % 4]], "w": 0}})
    names = {}
    pairs = []
    for p, q in rng.sample(PAIR_NAMES, rng.randint(1, 3)):
        names[len(names) + 1] = p
        names[len(names) + 1] = q
        pairs.append((len(names) - 1, len(names)))
    for name in rng.sample(SINGLE_NAMES, rng.randint(2, 4)):
        names[len(names) + 1] = name
    nets = len(names)
    for pair in pairs:
        for _ in range(rng.choice([1, 1, 2])):
            coupled_lines(rng, items, size, pair, copper, arcs)
    for _ in range(rng.randint(2, 10 if dense else 6)):
        x = rng.randint(2 * MM, size - 2 * MM) // 50_000 * 50_000
        y = rng.randint(2 * MM, size - 2 * MM) // 50_000 * 50_000
        layers = rng.choice([[0, 0], [last, last], [0, last]])
        items.append(pad(rng, rng.randint(2 * len(pairs) + 1, nets), (x, y), layers, layers == [0, last]))
    # (tracks and vias in the way, of other nets mostly, now and then of a pair's)
    n0 = len(items)
    polylines(rng, items, size, nets, copper, dense, arcs)
    singles = list(range(2 * len(pairs) + 1, nets + 1))
    for it in items[n0:]:
        if it.get("net", 0) <= 2 * len(pairs) and rng.random() < 0.97:
            it["net"] = rng.choice(singles)
    rules = {"clearance": rng.choice([100_000, 150_000, 200_000]), "holeClearance": 250_000, "holeToHole": 250_000,
             "edgeClearance": rng.choice([300_000, 500_000])}
    return {"layers": copper, "rules": rules, "items": items, "netNames": {str(k): v for k, v in names.items()},
            "stackupHeights": stackup_heights(rng, copper), "routes": [], "removeItems": True}


def dpmeander_route(rng, scene, items, area, length_of):
    """A random differential pair tuning, of the pair's length or its skew (now and then a single track's of one of
    its lines), as the tuning pattern generator starts one: on a track of a pair's net (now and then of another, or
    on a via or nothing), the pointer along it, as meander_route takes it"""
    names = {int(k): v for k, v in scene["netNames"].items()}
    pair_nets = {k for k in names if len(pair_of(scene, k)) == 2}
    tracks = [i for i, it in enumerate(items) if it["kind"] in ("track", "arc") and it["net"] in pair_nets]
    others = [i for i, it in enumerate(items) if it["kind"] in ("track", "arc") and it["net"] not in pair_nets]
    mode = rng.choice(["diffpair", "diffpair", "skew", "skew", "single"])
    pool = tracks if tracks and (not others or rng.random() < 0.93) else others or tracks
    sub = [it if i in pool else dict(it, kind="keep") for i, it in enumerate(items)]
    route = meander_route(rng, scene, sub, area, lambda r: None)
    route["tune"]["mode"] = mode
    probe = dict(route, tune=dict(route["tune"]))
    route["meander"] = meander_settings(rng, length_of(probe) if mode != "skew" else None)
    if mode == "skew":
        skew = length_of(probe)
        if skew is not None and rng.random() < 0.9:
            route["meander"]["targetSkew"] = skew + rng.choice([rng.randint(-20, 0), rng.randint(0, 20),
                                                                rng.randint(20, 120)]) * 50_000
            if rng.random() < 0.3:
                tol = rng.randint(1, 20) * 50_000
                route["meander"]["skewMin"] = route["meander"]["targetSkew"] - tol
                route["meander"]["skewMax"] = route["meander"]["targetSkew"] + tol
    return route


def dpmeander_routes(router, rng, scene, area, count):
    """`count` differential pair tunings on the scene's board, each on the board as the tunings before it left it,
    and what KiCad's router made of them (None if what it does is undefined); and how many were fixed"""
    items = list(scene["items"])
    routes, kicad, fixed = [], [], 0
    for _ in range(count):
        def length_of(tuning):
            probe = dict(tuning, moves=[])
            probe.pop("fix", None)
            k = route(router, dict(scene, items=items, routes=[probe]))
            return k[0].get("startLength") if k else None

        d = dpmeander_route(rng, scene, items, area, length_of)
        routes.append(d)
        kicad = route(router, dict(scene, routes=routes))
        if kicad is None:
            return None, 0
        r = kicad[-1]
        if r.get("fixed") or any(m.get("fixed") for m in r["moves"]):
            fixed += 1
        for k in reversed(r.get("removed", [])):
            del items[k]
        items += r["added"]
    return (routes, kicad), fixed


def meander_stats(cases):
    """How the tunings went: how many started and were fixed, how their last steps came out (too short, too long,
    tuned), how many measured a path through a via or ended with arcs in the tuned line"""
    rs = [k for c in cases for k in c["kicad"]]
    started = sum(k["started"] for k in rs)
    fixed = sum(bool(k.get("fixed")) or any(m.get("fixed") for m in k["moves"]) for k in rs)
    status = [0, 0, 0]
    for k in rs:
        last = [m for m in k["moves"] if "status" in m]
        if last:
            status[last[-1]["status"]] += 1
    vias = sum(any(p.get("kind") == "via" for p in k.get("tunedPath", [])) for k in rs)
    arcs = sum(any("arcs" in m.get("trace", {}) or "arcs" in m.get("p", {}) for m in k["moves"]) for k in rs)
    return (f"{started} started, {fixed} fixed, {status[0]} too short, {status[1]} too long, {status[2]} tuned, "
            f"{vias} measured through vias, {arcs} with arcs in their lines")


def route(router, scene):
    """What KiCad's router makes of the scene's routes; None if what it does is undefined (router.cpp's exit status
    3: an undo of a shoving route that KiCad's line placer gets wrong, reading a node it has deleted; its line placer
    reading an arc as a segment)"""
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


def boards(router, out, files, per_board, seed, mode="walkaround", arcs=False, rounded=False):
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
                done, shoving = drag_routes(router, rng, case, area, rng.randint(2, 6), arcs)
                if done is None:
                    undefined += 1
                    continue
                case["routes"], kicad = done
                drags += len(case["routes"])
                shoves += shoving
                cases.append({"name": f"{name}-drag-{seed}-{k}", "scene": case, "kicad": kicad})
                continue
            if mode in ("cdrag", "mdrag"):
                case["removeItems"] = True
                drags_of = component_drag_routes if mode == "cdrag" else multi_drag_routes
                done, kept = drags_of(router, rng, case, area, rng.randint(2, 5))
                if done is None:
                    undefined += 1
                    continue
                case["routes"], kicad = done
                cases.append({"name": f"{name}-{mode}-{seed}-{k}", "scene": case, "kicad": kicad})
                continue
            if mode in ("meander", "dpmeander"):
                case["removeItems"] = True
                tunings = meander_routes if mode == "meander" else dpmeander_routes
                done, fixed = tunings(router, rng, case, area, rng.randint(2, 5))
                if done is None:
                    undefined += 1
                    continue
                case["routes"], kicad = done
                cases.append({"name": f"{name}-{mode}-{seed}-{k}", "scene": case, "kicad": kicad})
                continue
            if mode == "diffpair":
                case["removeItems"] = True
                done, shoving = diffpair_routes(router, rng, case, area, rng.randint(2, 4))
                if done is None:
                    undefined += 1
                    continue
                case["routes"], kicad = done
                drags += len(case["routes"])
                shoves += shoving
                cases.append({"name": f"{name}-diffpair-{seed}-{k}", "scene": case, "kicad": kicad})
                continue
            case["routes"] = routes(rng, scene["items"], scene["layers"], area, count=rng.randint(2, 6), mode=mode,
                                    arcs=arcs, rounded=rounded)
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
          + (f", {shoves} of the {drags} pairs shoving, {pair_stats(cases)}" if mode == "diffpair" else "")
          + (f", {meander_stats(cases)}" if mode in ("meander", "dpmeander") else "")
          + (f", {cdrag_stats(cases)}" if mode == "cdrag" else "")
          + (f", {mdrag_stats(cases)}" if mode == "mdrag" else "")
          + (f", {arc_stats(cases)}" if arcs or rounded else "")
          + (f" ({undefined} left out, KiCad's router undefined on them)" if undefined else ""))


def pair_stats(cases):
    """How the pairs went: how many started, were finished, placed vias"""
    rs = [(r, k) for c in cases for r, k in zip(c["scene"]["routes"], c["kicad"])]
    started = sum(k["started"] for _, k in rs)
    finished = sum(any(m.get("fixed") for m in k["moves"]) or bool(k.get("fixed")) for _, k in rs)
    vias = sum(1 for _, k in rs for a in k["added"] if a["kind"] == "via")
    modes = {}
    for r, _ in rs:
        modes[r.get("mode", "walkaround")] = modes.get(r.get("mode", "walkaround"), 0) + 1
    return (f"{started} started, {finished} finished, {vias} vias placed, "
            + ", ".join(f"{v} {k}" for k, v in sorted(modes.items())))


def arc_stats(cases):
    """How the routes went with arcs: on boards with arc tracks, from an arc's end, arcs dragged, arcs shoved, routes
    in a rounded corner mode, and the arcs the routes put on"""
    rs = [(c["scene"], r, k) for c in cases for r, k in zip(c["scene"]["routes"], c["kicad"])]
    on = sum(any(it["kind"] == "arc" for it in s["items"]) for s, _, _ in rs)
    starts = dragged = 0
    for c in cases:
        # (the board as each route found it, what the routes before it took off and put on)
        items = list(c["scene"]["items"])
        for r, k in zip(c["scene"]["routes"], c["kicad"]):
            i = r["drag"]["item"] if "drag" in r else r["tune"]["item"] if "tune" in r else r.get("startItem", -1)
            if 0 <= i < len(items) and items[i]["kind"] == "arc":
                dragged += "drag" in r
                starts += "drag" not in r
            if c["scene"].get("removeItems"):
                for j in reversed(k.get("removed", [])):
                    del items[j]
            items += k["added"]
    rounded = sum(r.get("cornerMode", 0) in (1, 3) for _, r, _ in rs)
    put = sum(1 for _, _, k in rs for a in k["added"] if a["kind"] == "arc")
    lines = sum(1 for _, _, k in rs if any("arcs" in m.get("trace", m.get("head", {})) or
                                           any("arcs" in d for d in m.get("dragged", [])) for m in k["moves"]))
    return (f"{on} on boards with arc tracks, {starts} from arcs, {dragged} dragging arcs, {rounded} rounded, "
            f"{lines} with arcs in their lines on the way, {put} arcs put on")


def shoved(kicad):
    """Whether KiCad's router shoved anything aside on the board, on the way or in the end"""
    return any(r.get("removed") or any((m.get("node") or {}).get("removed") for m in r["moves"]) for r in kicad)


def main():
    args = sys.argv[1:]
    mode, shoving_only, real, arcs, rounded = "walkaround", False, False, False, False
    while args and args[0].startswith("--"):
        flag = args.pop(0)
        if flag == "--mode":
            mode = args.pop(0)
            if mode not in ("walkaround", "shove", "mix", "drag", "cdrag", "mdrag", "diffpair", "meander", "dpmeander"):
                sys.exit(f"scenes.py: no mode {mode}")
        elif flag == "--shoving":
            shoving_only = True
        elif flag == "--boards":
            real = True
        elif flag == "--arcs":
            arcs = True
        elif flag == "--rounded":
            rounded = True
        else:
            sys.exit(f"scenes.py: no option {flag}")
    if real:
        # scenes.py [--mode MODE] --boards KICAD_ROUTER OUT.json PER_BOARD SEED SCENE.json...
        boards(args[0], args[1], args[4:], int(args[2]), int(args[3]), mode, arcs, rounded)
        return
    router, out = args[0], args[1]
    count = int(args[2]) if len(args) > 2 else 40
    seed = int(args[3]) if len(args) > 3 else 20261016
    rng = random.Random(seed)
    cases = []
    prefix = ("random" if mode == "walkaround" else mode) + ("-arcs" if arcs else "") + ("-rounded" if rounded else "")
    n = 0
    undefined = 0
    quiet = 0
    drags = shoves = 0
    while len(cases) < count:
        # (a footprint drag's board has arc tracks on half of them, --arcs or not)
        scene = (diffpair_board(rng, n, arcs) if mode == "diffpair" else meander_board(rng, n, arcs)
                 if mode == "meander" else dpmeander_board(rng, n, arcs) if mode == "dpmeander"
                 else footprint_board(rng, n, arcs or rng.random() < 0.5) if mode == "cdrag"
                 else mdrag_board(rng, n, arcs) if mode == "mdrag"
                 else board(rng, n, mode, arcs, rounded))
        shoving = 0
        if mode in ("drag", "cdrag", "mdrag", "diffpair", "meander", "dpmeander"):
            area = board_area(scene)
            if mode == "cdrag":
                done, shoving = component_drag_routes(router, rng, scene, area, rng.randint(1, 5))
            elif mode == "mdrag":
                done, shoving = multi_drag_routes(router, rng, scene, area, rng.randint(1, 5))
            elif mode == "drag":
                done, shoving = drag_routes(router, rng, scene, area, rng.randint(1, 5), arcs)
            elif mode == "meander":
                done, shoving = meander_routes(router, rng, scene, area, rng.randint(1, 4))
            elif mode == "dpmeander":
                done, shoving = dpmeander_routes(router, rng, scene, area, rng.randint(1, 4))
            else:
                done, shoving = diffpair_routes(router, rng, scene, area, rng.randint(1, 4))
            kicad = None
            if done is not None:
                scene["routes"], kicad = done
        else:
            kicad = route(router, scene)
        if kicad is None:
            undefined += 1
        elif shoving_only and not (shoving if mode in ("drag", "diffpair") else shoved(kicad)):
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
          + (f", {shoves} of the {drags} pairs shoving, {pair_stats(cases)}" if mode == "diffpair" else "")
          + (f", {meander_stats(cases)}" if mode in ("meander", "dpmeander") else "")
          + (f", {cdrag_stats(cases)}" if mode == "cdrag" else "")
          + (f", {mdrag_stats(cases)}" if mode == "mdrag" else "")
          + (f", {arc_stats(cases)}" if arcs or rounded else "")
          + (f" ({undefined} more left out, KiCad's router undefined on them)" if undefined else "")
          + (f" ({quiet} more left out, nothing shoved on them)" if quiet else ""))


if __name__ == "__main__":
    main()
