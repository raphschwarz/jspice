# KiCad reference

The tools used to check JSpice's board router (`Sources/KiCadRouter`, ported from KiCad's) against KiCad's own code:
programs linked with KiCad 10.0.7's geometry library (`libs/kimath`), its polygon clipper (`thirdparty/clipper2`) and
its PCB editor's router (`pcbnew/router`), compiled from KiCad's sources as they are. They link KiCad's code, so they
are under KiCad's license, the GNU General Public License version 3 or later (see `../../KICAD-NOTICE.md`).

- `build.sh`: fetches the parts of KiCad's sources these need from KiCad's GitLab, compiles them (with a C++20
  compiler, wxWidgets 3.2, and Boost's and GLM's headers: on Ubuntu, `g++ libwxgtk3.2-dev libboost-dev libglm-dev`) and builds the
  programs. With no argument it writes the router tests' fixtures; with a number, sets of that many cases of each kind
  for `KICAD_GEOMETRY_REFERENCE` and `KICAD_CLIPPER_REFERENCE`.
- `geometry.cpp`: random cases, chosen to reach the corners (segments along the 45° directions or nearly, touching,
  overlapping, of no length; chains that share points; shapes close together), with KiCad's answers for them: vector
  lengths and resizing, `rescale`, segment distances, intersections and collisions, `DIRECTION_45` and the traces it
  starts, line chain simplification, splitting, intersections, inside tests and collisions, shape against shape
  collisions with their distances, and the router's hulls (`BuildHullForPrimitiveShape`) and where paths cross them
  (`HullIntersection`). `GeometryTests.swift` checks the port gives the same answers, to the nanometre.
  Also the line walkarounds (`LINE::Walkaround`) the router's walkaround mode is made of; arcs (`SHAPE_ARC`: their
  centres, angles, boxes, polylines, hulls, and collisions with every shape either way round, asked how close or
  not); pads' shapes as KiCad makes them polygons (rectangles with rounded or cut corners, trapezoids, circles,
  grown or shrunk, the error inside or outside); polygons cut into triangles as KiCad cuts zones and keepouts
  (`POLYGON_TRIANGULATION`: star-shaped, convex and rectilinear outlines, points crowded or in line, outlines with a
  hole fractured in, chains that cross themselves, where KiCad's own cutting subdivides, splits or fails); and polygon
  sets as KiCad's router cuts a keepout zone's outline (`SHAPE_POLY_SET::CacheTriangulation( false )`: outlines with
  holes in them, across them and over each other, holes touching the outline and each other, outlines that touch or
  cross themselves, points in line and repeated, spikes, waists of no width, several outlines and islands in holes,
  many points, points and holes crowded within its 50 nm, outlines like real keepouts', degenerate ones, on grids of a
  nanometre to ten millimetres; then a few found to need its second try, or to fail it), with what `Simplify` and
  `Fracture` make of each on the way and the fractured outlines split where they touch themselves (each case in a
  child process, as `clipper.cpp`'s). `kicad-geometry COUNT SEED` makes other random cases than `build.sh`'s.
- `router.cpp`: KiCad's interactive router itself (`PNS::ROUTER` with its line placer, walkaround, shove,
  optimizer) on a board given as JSON: pads, tracks, vias, an outline, simple clearance rules, and the routes to make
  on it, step by step as the router tool drives it (pointer moves, with the item under the pointer if one is given,
  vias, layer switches, clicks that fix part of a route, undo, posture flips; walking around obstacles, shoving them
  or marking them). It writes the head, tail and trace after each step, what each route fixed and what it put on the
  board, and why the router would not start a route it refused. For a scene that asks (`"removeItems": true`) it
  also writes what each route took off the board (a route that shoves a track replaces it), which the routes after
  it then no longer find there, and, after each step, the board as the router has it then (the branch it is routing
  on: what the shove has pushed where, and what has sprung back), when it has changed. `RouterTests.swift` routes
  the same boards with the port, with the same rules (`SceneRouting.swift`), and must get the same, point for point.
  An undo that would leave KiCad's shove holding a branch the undo deletes (its springback stack keeps branches of a
  fixed stage the undo kills) is where KiCad's behaviour is undefined, a use after free; `router.cpp` sees it coming
  and stops with exit status 3, and `scenes.py` leaves such boards out. (Valgrind finds one more slip in KiCad's
  shove, which changes nothing: a line's destructor asks a via already freed with its branch whether the line owns
  it.) A shove gives up after a second by the clock (`ROUTING_SETTINGS::ShoveTimeLimit`), which would make what it
  does depend on how fast the machine is; `router.cpp` and the tests set no time limit, and both stop on the
  iteration limit alone. A board can also be a real one as `board-scene.py` gives it (`"rules": {"board": true,
  ...}`): every item KiCad's router takes from a board (pads, drawings and texts on copper, outlines, keepout zones,
  which it cuts into triangles as KiCad does, tracks, vias) with the clearances KiCad's rule resolver would give it
  (net classes, pads' and footprints' own clearances, the board's minimums, hole and edge clearances). One case in
  `kicad-board-routes.json` keeps what KiCad's router does on a board whose hole clearance is 0: it takes tracks
  along a mounting hole's very edge, which KiCad's DRC then finds touching the hole (`BoardRoutingTests` measures
  such contacts and fails only on a track that cuts in).
- `board-scene.py`: what KiCad's router sees of a real board (`board-scene.py BOARD.kicad_pcb [OUT.json]`, through
  KiCad's `pcbnew` Python module): the items `PNS_KICAD_IFACE_BASE::SyncWorld` makes of it, in its order, with their
  shapes as KiCad's own `GetEffectiveShape` gives them, the board's rules as KiCad's design rules engine resolves
  them, and its nets. `BoardWorldTests.swift` reads the same board with `BoardWorld` and must find the same items,
  shapes and rules, to the nanometre (custom pads aside, whose outlines need polygon merging the port lacks yet).
- `boards.py`: random boards made by KiCad itself (`boards.py OUTDIR COUNT [SEED]`): footprints from KiCad's own
  libraries with every kind of pad, turned and flipped, on two or four layers; nets in net classes chosen by
  pattern, of different priorities; pads' and footprints' own clearances; tracks, vias, drawings on copper; outlines
  with rounded corners (arcs, or a rectangle's own corner radius) and round cut-outs. Each is saved with its
  project, and `board-scene.py` run on it.
  `Tests/KiCadRouterTests/Fixtures/boards` holds three; `KICAD_BOARD_REFERENCE` names another folder of them.
- `scenes.py`: random boards for `router.cpp` (two and four layers, sparse and crowded; rectangular, round, oval and
  turned pads, surface mount and through-hole, unplated holes; tracks already there) with random routes on them
  (now and then one starting on an unplated hole), and KiCad's answers: `scenes.py KICAD_ROUTER OUT.json [COUNT [SEED]]`. The router tests' fixture is
  `scenes.py ... ../../Tests/KiCadRouterTests/Fixtures/kicad-routes.json 60`. With `--boards`, random routes on real
  boards (`board-scene.py`'s scenes): `scenes.py --boards KICAD_ROUTER OUT.json ROUTES_PER_BOARD SEED SCENE.json...`;
  `kicad-board-routes.json` is `scenes.py --boards ... 2 20261016 ../../Tests/KiCadRouterTests/Fixtures/boards/*.json`.
  With `--mode shove`, routes that shove (most of them; some walk round or mark) on boards with more to shove:
  tracks of a few segments at 45 and 90 degrees, some from pads, some through vias, some locked, and vias of their
  own; with `--mode mix`, the three modes evenly; `--shoving` keeps only boards on which something was shoved. Both
  take `--boards` too. `kicad-shove-routes.json` is
  `scenes.py --mode shove --shoving ... ../../Tests/KiCadRouterTests/Fixtures/kicad-shove-routes.json 35 20261016`.
  `KICAD_ROUTER_REFERENCE` names others (separated by colons).
- `clipper.cpp`: the polygon clipper KiCad ships (`thirdparty/clipper2`, Clipper2, compiled as KiCad compiles it: its
  points carry a z value) on random cases, with its answers: boolean operations (union, intersection, difference,
  exclusive or, under every fill rule; open paths too; collinear points kept or not, solutions reversed or not) on
  polygons chosen to reach the corners (on small grids, so that points repeat and edges touch, overlap and cross;
  holes; rings of many points; combs; long flat edges; the clip the subject moved a little), and offsets (every join
  and end type, out and in, miter limits and arc tolerances, and KiCad's simplification after), as paths and as trees
  of outlines and holes, with the z callback KiCad follows its arcs with; and the helpers (areas, point in polygon,
  simplification) and the order `std::sort` leaves equal elements in (Clipper2 sorts each scanbeam's crossings with
  it). After the random boolean operations come a few found to take Clipper2 down its rarest ways, two of which it
  goes round for ever (KiCad's copy crashes on them: each case runs in a child process, and those are marked as such).
  `ClipperTests.swift` checks the port gives the same, point for point and z value for z value, and finishes where
  KiCad's copy crashes. `kicad-clipper COUNT SEED` makes other random cases than `build.sh`'s.
- `patch.py`: the changes `build.sh` makes to KiCad's router before building it, so it answers the same each
  run and runs on items with no board item behind them: obstacles met at the same place are ordered by when their
  items were made rather than by their addresses in memory; a node's items go into a branch, and a branch's changes
  are taken, in that order too, rather than in the order of a hash set of pointers; virtual vias are made for joints
  in the order of their places rather than of a hash map's (the port does all three in the same order); a start
  pad's board item is asked its type only when it has one; and why a route cannot start on a non-routable item (a
  hole with no plating, a rule area, a text), which KiCad asks the item's board item, is asked of `router.cpp` when
  there is none.
- `stubs.cpp`: what the router and KiCad's settings call from the rest of KiCad, as these programs need it (no
  program object, no settings folder, no boards), and the hook `router.cpp` answers that last question through.

With `KICAD_ROUTER_DEBUG` set, `router.cpp` writes KiCad's router debug messages to standard error, and the router
tests write the port's in the same form, to compare the two where a route differs.

`BoardRoutingTests.swift` goes one step further, with KiCad's own design rules check as the judge: it routes pads of
the same net on real boards with `BoardRouter` (the port, on the board's world, writing what it places into the
board file), and runs `kicad-cli pcb drc` on the result; no clearance, crossing, short or size violation may
involve a track or via the router placed.

CI (`.github/workflows/kicad.yml`) builds them and checks the port against 2000 geometry cases of each kind, 2000
clipper cases of each kind, 1000 random router boards, 400 random boards with routes that shove, and 60 real boards
made by `boards.py` (their worlds, routes on them that walk round, mark and shove, and KiCad's DRC on the port's
routes); each run has a new seed, the run number, which the names a failure reports carry.
