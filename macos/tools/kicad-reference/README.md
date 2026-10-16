# KiCad reference

The tools used to check JSpice's board router (`Sources/KiCadRouter`, ported from KiCad's) against KiCad's own code:
programs linked with KiCad 10.0.7's geometry library (`libs/kimath`) and its PCB editor's router (`pcbnew/router`),
compiled from KiCad's sources as they are. They link KiCad's code, so they are under KiCad's license, the GNU General
Public License version 3 or later (see `../../KICAD-NOTICE.md`).

- `build.sh`: fetches the parts of KiCad's sources these need from KiCad's GitLab, compiles them (with a C++20
  compiler, wxWidgets 3.2, and Boost's and GLM's headers: on Ubuntu, `g++ libwxgtk3.2-dev libboost-dev libglm-dev`) and builds the
  programs. With no argument it writes the router tests' fixture; with a number, a set of that many cases of each kind
  for `KICAD_GEOMETRY_REFERENCE`.
- `geometry.cpp`: random cases, chosen to reach the corners (segments along the 45° directions or nearly, touching,
  overlapping, of no length; chains that share points; shapes close together), with KiCad's answers for them: vector
  lengths and resizing, `rescale`, segment distances, intersections and collisions, `DIRECTION_45` and the traces it
  starts, line chain simplification, splitting, intersections, inside tests and collisions, shape against shape
  collisions with their distances, and the router's hulls (`BuildHullForPrimitiveShape`) and where paths cross them
  (`HullIntersection`). `GeometryTests.swift` checks the port gives the same answers, to the nanometre.
  Also the line walkarounds (`LINE::Walkaround`) the router's walkaround mode is made of; arcs (`SHAPE_ARC`: their
  centres, angles, boxes, polylines, hulls, and collisions with every shape either way round, asked how close or
  not); and pads' shapes as KiCad makes them polygons (rectangles with rounded or cut corners, trapezoids, circles,
  grown or shrunk, the error inside or outside).
- `router.cpp`: KiCad's interactive router itself (`PNS::ROUTER` with its line placer, walkaround, optimizer) on a
  board given as JSON: pads, tracks, vias, an outline, simple clearance rules, and the routes to make on it, step by
  step as the router tool drives it (pointer moves, vias, layer switches, clicks that fix part of a route, undo,
  posture flips; walking around obstacles or marking them). It writes the head, tail and trace after each step, what
  each route fixed and what it put on the board. `RouterTests.swift` routes the same boards with the port, with the
  same rules (`SceneRouting.swift`), and must get the same, point for point.
- `scenes.py`: random boards for `router.cpp` (two and four layers, sparse and crowded; rectangular, round, oval and
  turned pads, surface mount and through-hole, unplated holes; tracks already there) with random routes on them,
  and KiCad's answers: `scenes.py KICAD_ROUTER OUT.json [COUNT [SEED]]`. The router tests' fixture is
  `scenes.py ... ../../Tests/KiCadRouterTests/Fixtures/kicad-routes.json 60`; `KICAD_ROUTER_REFERENCE` names
  another.
- `patch.py`: the two changes `build.sh` makes to KiCad's router before building it, so it answers the same each
  run: obstacles met at the same place are ordered by when their items were made rather than by their addresses in
  memory (the port orders them the same way), and a start pad's board item is asked its type only when it has one.
- `stubs.cpp`: what the router and KiCad's settings call from the rest of KiCad, as these programs need it (no
  program object, no settings folder, no boards).

With `KICAD_ROUTER_DEBUG` set, `router.cpp` writes KiCad's router debug messages to standard error, and the router
tests write the port's in the same form, to compare the two where a route differs.

CI (`.github/workflows/kicad.yml`) builds them and checks the port against 2000 geometry cases of each kind and 1000
random boards (a new seed each run, the run number; the scene names a failure reports carry it).
