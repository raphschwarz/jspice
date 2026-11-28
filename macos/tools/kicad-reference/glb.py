#!/usr/bin/env python3
"""A binary glTF 2.0 file (.glb, as `kicad-cli pcb export glb` writes it) read with Python's standard library alone
(struct and json), for checking the port's reader (KiCadRouter's GLTFAsset) against a reading of its own: the glTF
2.0 specification's, not the port's code. Written as JSON to standard output:

- "nodes": each node in the file's order: its name, its mesh, its children, its world matrix (the scene's root nodes'
  own, each child's its parent's times its own: a node's "matrix", column by column, or its translation, rotation (a
  unit quaternion) and scale as T * R * S) and, for a node with a mesh, the number of triangles and the box round
  their corners moved by that matrix;
- "meshes": each mesh's primitives: mode, how many vertices (POSITION's count), whether there are normals, the
  material, how many triangles (TRIANGLES: the indices, or the vertices, in threes; TRIANGLE_STRIP and TRIANGLE_FAN:
  two fewer than their corners; other modes none) and the first and last triangle's corners;
- "materials": each material's base colour, metallic and roughness factors (the specification's defaults where it
  gives none);
- "scene": the scene's root nodes.

Every number is written as Python's float.hex() writes it, so that the port's numbers can be compared exactly. The
arithmetic is done in doubles, in the order the port's Matrix4 does it (m[column][row]; a product's each entry the sum
over k from 0 of a[k][row] * b[column][k], from 0.0; a point's each coordinate m[0] * x + m[1] * y + m[2] * z + m[3]).

    glb.py FILE.glb
"""

import json
import struct
import sys

COMPONENTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
FORMATS = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}


def h(x):
    return float(x).hex()


def read(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, version, length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67 or version != 2:
        raise SystemExit("not a glTF 2.0 binary file")
    at = 12
    doc, binary = None, b""
    while at + 8 <= min(length, len(data)):
        size, kind = struct.unpack_from("<II", data, at)
        chunk = data[at + 8:at + 8 + size]
        if kind == 0x4E4F534A:
            doc = json.loads(chunk.decode("utf-8"))
        elif kind == 0x004E4942 and not binary:
            binary = chunk
        at += 8 + size
    return doc, binary


def accessor(doc, binary, index):
    """The accessor's elements, each a list of its components (normalized integers left as they are)"""
    a = doc["accessors"][index]
    n = COMPONENTS[a["type"]]
    fmt = FORMATS[a["componentType"]]
    size = struct.calcsize("<" + fmt)
    count = a["count"]
    if "bufferView" not in a:
        return [[0] * n for _ in range(count)]
    view = doc["bufferViews"][a["bufferView"]]
    start = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = view.get("byteStride") or n * size
    out = []
    for i in range(count):
        out.append(list(struct.unpack_from("<" + fmt * n, binary, start + i * stride)))
    return out


def multiply(a, b):
    out = [[0.0] * 4 for _ in range(4)]
    for c in range(4):
        for r in range(4):
            v = 0.0
            for k in range(4):
                v += a[k][r] * b[c][k]
            out[c][r] = v
    return out


def local(node):
    if "matrix" in node:
        m = [float(v) for v in node["matrix"]]
        return [m[0:4], m[4:8], m[8:12], m[12:16]]
    tx, ty, tz = [float(v) for v in node.get("translation", [0, 0, 0])]
    x, y, z, w = [float(v) for v in node.get("rotation", [0, 0, 0, 1])]
    sx, sy, sz = [float(v) for v in node.get("scale", [1, 1, 1])]
    # the rotation's rows
    r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    s = [sx, sy, sz]
    m = [[r[row][col] * s[col] for row in range(3)] + [0.0] for col in range(3)]
    m.append([tx, ty, tz, 1.0])
    return m


def apply(m, p):
    x, y, z = p
    return [m[0][0] * x + m[1][0] * y + m[2][0] * z + m[3][0],
            m[0][1] * x + m[1][1] * y + m[2][1] * z + m[3][1],
            m[0][2] * x + m[1][2] * y + m[2][2] * z + m[3][2]]


def triangles(mode, corners):
    """The primitive's triangles as triples of its corners (indices into its vertices)"""
    n = len(corners)
    if mode == 4:
        return [corners[i:i + 3] for i in range(0, n - n % 3, 3)]
    if mode == 5:
        return [[corners[i], corners[i + 1 + i % 2], corners[i + 2 - i % 2]] for i in range(n - 2)]
    if mode == 6:
        return [[corners[i + 1], corners[i + 2], corners[0]] for i in range(n - 2)]
    return []


def main():
    doc, binary = read(sys.argv[1])
    meshes = []
    tris = []
    for mesh in doc.get("meshes", []):
        prims = []
        mt = []
        for p in mesh.get("primitives", []):
            positions = accessor(doc, binary, p["attributes"]["POSITION"])
            corners = [i[0] for i in accessor(doc, binary, p["indices"])] if "indices" in p else list(range(len(positions)))
            mode = p.get("mode", 4)
            t = triangles(mode, corners)
            mt.append((positions, t))
            prims.append({"mode": mode, "vertices": len(positions), "normals": "NORMAL" in p["attributes"],
                          "material": p.get("material", -1), "triangles": len(t),
                          "first": t[0] if t else [], "last": t[-1] if t else []})
        meshes.append({"name": mesh.get("name", ""), "primitives": prims})
        tris.append(mt)
    nodes = doc.get("nodes", [])
    world = [None] * len(nodes)
    scene = doc.get("scenes", [{}])[doc.get("scene", 0)].get("nodes", []) if doc.get("scenes") else []

    def walk(i, parent):
        world[i] = local(nodes[i]) if parent is None else multiply(parent, local(nodes[i]))
        for c in nodes[i].get("children", []):
            walk(c, world[i])

    for i in scene:
        walk(i, None)
    out_nodes = []
    for i, node in enumerate(nodes):
        entry = {"name": node.get("name", ""), "mesh": node.get("mesh", -1), "children": node.get("children", [])}
        if world[i] is not None:
            entry["world"] = [h(v) for col in world[i] for v in col]
            if "mesh" in node:
                lo, hi = [float("inf")] * 3, [float("-inf")] * 3
                count = 0
                for positions, t in tris[node["mesh"]]:
                    count += len(t)
                    for tri in t:
                        for k in tri:
                            q = apply(world[i], [float(v) for v in positions[k]])
                            lo = [min(a, b) for a, b in zip(lo, q)]
                            hi = [max(a, b) for a, b in zip(hi, q)]
                entry["triangles"] = count
                if count:
                    entry["bounds"] = [h(v) for v in lo + hi]
        out_nodes.append(entry)
    materials = []
    for m in doc.get("materials", []):
        pbr = m.get("pbrMetallicRoughness", {})
        materials.append({"name": m.get("name", ""), "baseColor": [h(v) for v in pbr.get("baseColorFactor", [1, 1, 1, 1])],
                          "metallic": h(pbr.get("metallicFactor", 1)), "roughness": h(pbr.get("roughnessFactor", 1))})
    json.dump({"nodes": out_nodes, "meshes": meshes, "materials": materials, "scene": scene}, sys.stdout,
              separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
