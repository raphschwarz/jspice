# KiCad reference

The tools used to check JSpice's board router (`Sources/KiCadRouter`, ported from KiCad's) against KiCad's own code:
programs linked with KiCad 10.0.7's geometry library (`libs/kimath`), its polygon clipper (`thirdparty/clipper2`) and
its PCB editor's router (`pcbnew/router`), compiled from KiCad's sources as they are. They link KiCad's code, so they
are under KiCad's license, the GNU General Public License version 3 or later (see `../../KICAD-NOTICE.md`).

- `build.sh`: fetches the parts of KiCad's sources these need from KiCad's GitLab, compiles them (with a C++20
  compiler, wxWidgets 3.2, and Boost's and GLM's headers: on Ubuntu, `g++ libwxgtk3.2-dev libboost-dev libglm-dev`) and builds the
  programs. With no argument it writes the router tests' fixtures; with a number, sets of that many cases of each kind
  for `KICAD_GEOMETRY_REFERENCE`, `KICAD_CLIPPER_REFERENCE` and `KICAD_ARC_GEOMETRY_REFERENCE`. It compiles KiCad's
  code with `NDEBUG`, as KiCad's release builds are compiled: KiCad's plain assertions are left out, as they are in
  the KiCad its users run, which goes on past one of them (the shove's, that a via it moves ends a line's first or
  last segment, which it need not when the line has arcs).
- `geometry.cpp`: random cases, chosen to reach the corners (segments along the 45° directions or nearly, touching,
  overlapping, of no length; chains that share points; shapes close together), with KiCad's answers for them: vector
  lengths and resizing, `rescale`, segment distances, intersections and collisions, `DIRECTION_45` and the traces it
  starts, line chain simplification, splitting, intersections, inside tests and collisions, shape against shape
  collisions with their distances, and the router's hulls (`BuildHullForPrimitiveShape`) and where paths cross them
  (`HullIntersection`), and points triangulated as the ratsnest triangulates a net's anchors (`delaunator`: its
  triangles and half edges). `GeometryTests.swift` checks the port gives the same answers, to the nanometre.
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
  With `--arcs` (`kicad-geometry --arcs COUNT [SEED]`), chains of segments and arcs as the router keeps a track's
  path (`SHAPE_LINE_CHAIN` with its arcs: each built from points and arcs, arcs one after another sharing the point
  between them, some closed, some ending where they start), and what KiCad makes of each: which point is on which arc,
  the next shape, its length; the chain cut (`Slice`), spliced (`Remove`, `RemoveShape`, `Replace`, `Insert`,
  `Append`), split at a point, a point moved, turned round, simplified each way, its arcs made points, closed or
  opened; the nearest point; collisions with points, segments and shapes (other chains with arcs, arcs, pads'
  shapes) both ways round, asked how close or not; the traces `DIRECTION_45` starts in each corner mode, rounded
  ones too; paths with arcs walked round a hull (what the walk leaves of the path keeps its arcs); and a line's arc
  dragged (`LINE::DragArc`). Each case runs in a child process: one of KiCad's assertions might stop it (none has),
  and a closed chain's nearest end of an arc is not asked, as KiCad reads past its points there.
  `ArcGeometryTests.swift` checks the port keeps the same points, the same arcs (to their centres: an arc turned
  round keeps the centre it had) and the same note of which point is on which arc. The fixture,
  `kicad-arc-geometry.json`, is `kicad-geometry --arcs 25`.
- `router.cpp`: KiCad's interactive router itself (`PNS::ROUTER` with its line placer, diff pair placer, walkaround,
  shove, dragger, optimizer) on a board given as JSON: pads, tracks, vias, an outline, simple clearance rules, and the routes to make
  on it, step by step as the router tool drives it (pointer moves, with the item under the pointer if one is given,
  vias, layer switches, clicks that fix part of a route, undo, posture flips; walking around obstacles, shoving them
  or marking them). It writes the head, tail and trace after each step, what each route fixed and what it put on the
  board, and why the router would not start a route it refused. For a scene that asks (`"removeItems": true`) it
  also writes what each route took off the board (a route that shoves a track replaces it), which the routes after
  it then no longer find there, and, after each step, the board as the router has it then (the branch it is routing
  on: what the shove has pushed where, and what has sprung back), when it has changed. `RouterTests.swift` routes
  the same boards with the port, with the same rules (`SceneRouting.swift`), and must get the same, point for point.
  Tracks can be arcs (`"kind": "arc"`, their start, mid and end: `syncArc`'s `PNS::ARC`), and a route can turn its
  corners in any of KiCad's corner modes (`"cornerMode"`: 0 mitred at 45°, KiCad's default, 1 rounded at 45°, 2
  mitred at 90°, 3 rounded at 90°); the lines it writes then carry their arcs (each one's start, mid, end and centre)
  and which point is on which (`"shapes"`), and what a route puts on and takes off can be arcs. Where KiCad's line
  placer reads an arc as a segment (`simplifyNewLine` takes what is at a joint it tidies for a `SEGMENT`, whatever it
  is), which is undefined, `patch.py` has it say so and `router.cpp` stops with exit status 3; `scenes.py` leaves
  such boards out. Valgrind finds nothing wrong in KiCad's router on scenes with arcs and rounded corners (47 of
  them, of every mode, real boards among them).
  An undo that would leave KiCad's shove holding a branch the undo deletes (its springback stack keeps branches of a
  fixed stage the undo kills) is where KiCad's behaviour is undefined, a use after free; `router.cpp` sees it coming
  and stops with exit status 3, and `scenes.py` leaves such boards out. (Valgrind finds one more slip in KiCad's
  shove, which changes nothing: a line's destructor asks a via already freed with its branch whether the line owns
  it.) A shove gives up after a second by the clock (`ROUTING_SETTINGS::ShoveTimeLimit`), which would make what it
  does depend on how fast the machine is; `router.cpp` and the tests set no time limit, and both stop on the
  iteration limit alone. A board can also be a real one as `board-scene.py` gives it (`"rules": {"board": true,
  ...}`): every item KiCad's router takes from a board (pads, drawings and texts on copper, outlines, keepout zones,
  which it cuts into triangles with KiCad's code as `syncZone` does, leaving out one it cannot cut, and writes with
  the first route, tracks, vias) with the clearances KiCad's rule resolver would give it
  (net classes, pads' and footprints' own clearances, the board's minimums, hole and edge clearances). One case in
  `kicad-board-routes.json` keeps what KiCad's router does on a board whose hole clearance is 0: it takes tracks
  along a mounting hole's very edge, which KiCad's DRC then finds touching the hole (`BoardRoutingTests` measures
  such contacts and fails only on a track that cuts in).
  A route can be a drag instead (`"drag": {"item": INDEX, "at": POINT, "freeAngle": true}`): KiCad's dragger
  (`PNS::DRAGGER`, started by `ROUTER::StartDragging` as the router tool's drag (D) and free angle drag (G) start it)
  drags the track's segment, or its corner where the point is within half the track's width of one of its ends (or the
  virtual via there, where the track's width changes, three tracks meet or a locked one ends), or the via with the
  tracks on it, walking round what is in its way, shoving it or marking it, through the route's pointer positions and
  clicks (a click with Ctrl held, `{"fix": POINT, "force": true}`, keeps a drag that collides, marking obstacles; one
  that is kept ends the drag). After each step it writes whether the move worked, what the dragger dragged
  (`DRAGGER::Traces`), whether it is marking obstacles (its first move failed) and whether what it drags is clear, and
  the board as the dragger has it, when it has changed; then what the drag kept put on the board and took off it. The
  router's settings for a drag: the whole dragged track optimized (`"optimizeEntire": true`), its segments not
  smoothed (`"smooth": false`), violations allowed marking obstacles (`"allowViolations": true`). A drag kept deletes
  the dragger's branches of the world (`NODE::Commit` lets go of them), and `router.cpp` asks the dragger nothing more
  then. Valgrind finds nothing wrong in KiCad's dragger on these scenes but the shove's slip above, when a drag that
  shoved a via is over and its shove deleted, which changes nothing.
  A route can be a differential pair (`"diffPair": true`, the router tool's Route Differential Pair): KiCad's diff
  pair placer (`PNS::DIFF_PAIR_PLACER`, in the router's `PNS_MODE_ROUTE_DIFF_PAIR`) routes the pair from the pad, via
  or track end the route starts on and the nearest of the same kind of its coupled net's. Which nets are pairs goes
  by the names the scene gives them (`"netNames"`), as `BOARD::MatchDpSuffix` has it: a last P or N, + or - (digits
  and underscores after it aside), the net with the other the coupled one. The pair goes at its width and gap
  (`"dpWidth"`, `"dpGap"`, and `"dpViaGap"` for its vias' own), its vias' holes kept the rules' hole to hole and hole
  clearances apart (as `ImportSizes` takes them), and `"minClearance"` is the board's minimum clearance, a gap under
  which refuses the start; it goes through the route's pointer positions (the last with a pad, via or track end of the
  pair's nets under it, where the pair snaps to the pair there), vias, layer switches (which a pair makes only from its
  vias), posture flips, clicks (`"fixAll": false`: all of the pair but its last segments fixed) and undo (which a
  pair's placer has none of). After each step it writes the pair's two lines (`DIFF_PAIR_PLACER::Traces`), for each
  move whether the pair got there clear, and the board as the placer has it, when it has changed. A pair's placer
  commits each part as it is fixed, so what it takes off the board is gone for the rest of the route too: an item the
  route names after a fix took it off is nothing under the pointer, and what a fix takes off of what an earlier one
  of the same route put on was not put on after all. A fix with no move since the last one (whose node the placer let
  go of) has KiCad's placer add the pair to a node it has not got, a null pointer; `router.cpp` sees it coming and
  stops with exit status 3, and `scenes.py` leaves such boards out. Valgrind finds nothing wrong in KiCad's pair placer
  on these scenes but the shove's slip above (a pair's vias are the shove's heads' vias). Two of KiCad's ways a pair
  goes that are its own: walking round, a pair none of whose walks clears what is in its way is left with no path at
  all, and counts as clear (`tryWalkDp` takes its best walk, a pair with no path if there was none, whenever its best
  score is above 0, which it always is); and shoving, the vias a pair ends in are committed where they were made, not
  where the shove pushed them, off the pair's tracks. The port does both.
- `board-scene.py`: what KiCad's router sees of a real board (`board-scene.py BOARD.kicad_pcb [OUT.json]`, through
  KiCad's `pcbnew` Python module): the items `PNS_KICAD_IFACE_BASE::SyncWorld` makes of it, in its order, with their
  shapes as KiCad's own `GetEffectiveShape` gives them, the board's rules as KiCad's design rules engine resolves
  them, and its nets. `BoardWorldTests.swift` reads the same board with `BoardWorld` and must find the same items,
  shapes and rules, to the nanometre: custom pads too, their anchors and pieces merged into one outline as KiCad
  merges them (a pad with a curve among its pieces aside: the port draws a convex outline round it, and says so);
  vias with their types (blind, buried, micro), which `router.cpp` gives KiCad's router's vias and writes with those
  a route puts on (a via shoved or dragged keeps its type, and the port writes it back into the board so).
- `boards.py`: random boards made by KiCad itself (`boards.py [--custom-pads] OUTDIR COUNT [SEED]`; on four layers,
  blind, buried and micro vias too, from random numbers of their own): footprints from KiCad's own
  libraries with every kind of pad, turned and flipped, on two or four layers; nets in net classes chosen by
  pattern, of different priorities; pads' and footprints' own clearances; tracks, vias, drawings on copper; outlines
  with rounded corners (arcs, or a rectangle's own corner radius) and round cut-outs; keepout zones of several shapes
  on some of the copper layers, some with holes, some in footprints, now and then one KiCad's router cannot cut into
  triangles (drawn from random numbers of their own, so that the rest of each board is what it was before they were
  added); on half of them copper zones (of a net or none, on one layer or a few, of different priorities and pad
  connections, also from random numbers of their own), filled by KiCad's zone filler. Each is saved with its project, and `board-scene.py` run on it. With `--custom-pads`, the footprints are
  drawn from all of KiCad's library footprints with a custom pad instead (some 600: pads of polygons, lines, arcs,
  circles and rings, rectangles, filled or outlined, of some width or none; keepout zones of their own, some with
  arcs, some on no copper layer).
  `Tests/KiCadRouterTests/Fixtures/boards` holds five (`random-2-43` and `random-2-51`, with keepout zones, as
  `boards.py` makes them now; the other three as it made them before it drew keepouts and rounded rectangles);
  `KICAD_BOARD_REFERENCE` names another folder of them. With `--pairs` (`boards.py --pairs OUTDIR COUNT [SEED]`),
  boards with differential pairs to route instead: a connector and a chip, two pairs of their pads (pins 1 and 2, 3
  and 4) of two pairs' nets, the pairs in a net class with a diff pair width and gap of its own or in the default
  class; resistors and tracks of other nets across the way. `Tests/KiCadRouterTests/Fixtures/pairboards` holds three
  (`boards.py --pairs ... 3 20261026`). With `--arcs`, arc tracks too, from random numbers of their own (so that the
  rest of each board is as it is without them): lines of segments and arcs, each arc tangent to the segments either
  side, out of pads of their net or from anywhere, some arcs one after another, now and then a locked one.
  `Tests/KiCadRouterTests/Fixtures/arcboards` holds three (`boards.py --arcs ... 3 20261103`).
- `drc.py`: kicad-cli's design rules check of boards (`drc.py BOARD.kicad_pcb...`): its report of each, as the
  board is (its zones not refilled), errors and warnings, next to it as `BOARD.drc` (JSON, its date taken out).
  `DRCTests` checks the port's DRC (`BoardDRC`) against it: the same violations of the checks it makes, between the
  same items, in the same words. The boards of `Tests/KiCadRouterTests/Fixtures/boards` have theirs.
- `courtyards.py`: KiCad's courtyards of boards' footprints (`courtyards.py BOARD.kicad_pcb...`): each footprint's
  `FOOTPRINT::BuildCourtyardCaches`, through KiCad's `pcbnew` module, its front and back courtyards (each polygon's
  outline and holes, their points), the width it gives the first outline and whether it found either side
  malformed, next to the board as `BOARD.courtyards` (JSON). `CourtyardTests` checks the port's
  (`BoardDRC.courtyards`, made with `Outlines.convertOutlineToPolygon`, the port of `ConvertOutlineToPolygon`)
  against it, point for point. With `--draw OUT.kicad_pcb`, a board of footprints whose courtyards are drawn to take
  the conversion down its other ways (holes, islands in them, holes and outlines crossing, chains that do not close,
  close within the chaining distance, cross themselves or branch, arcs, circles, curves, rounded rectangles and
  rectangles turned off square, a chain through the origin, where a polygon's ends are); with
  `--random OUT.kicad_pcb COUNT [SEED]`, footprints of random courtyards (outlines of lines, arcs and curves in no
  order, some drawn the other way round, their ends now and then a little apart, with circles, rectangles, polygons
  and other outlines inside them, across them or beside them; every other arc's ends then swapped in the file, as
  other tools may write them). `Tests/KiCadRouterTests/Fixtures/courtyards` holds `drawn` (`--draw`) and `random`
  (`--random ... 60 20261104`), and the boards of `Fixtures/boards` have theirs too.
- `outlines.py`: boards whose outlines take KiCad's outline check (`invalid_outline`) down its ways (`outlines.py
  OUT`): no edges, drawings too small to see, outlines crossing, chains open, branching or doubling back, arcs,
  circles, curves, rounded rectangles and polygons, some filled, footprints' outlines that are holes in the board's
  and those that are not, each board with kicad-cli's report next to it (`drc.py`'s), no project of its own.
  `Tests/KiCadRouterTests/Fixtures/outlines` holds them, which `DRCTests` checks.
- `copper.py`: each copper layer's copper as KiCad's sliver check makes it (`copper.py BOARD.kicad_pcb...`): through
  KiCad's `pcbnew` module, each item on the layer in `forEachGeometryItem`'s order made polygons by its
  `TransformShapeToPolygon` (ARC_LOW_DEF, the error inside), zones by their fills, all united, next to the board as
  `BOARD.copper` (JSON: each layer's polygons, outline and holes). `CopperTests` checks the port's
  (`BoardDRC.copperLayerPolygons`) against it, point for point. With `--draw OUT.kicad_pcb`, a board of copper of the
  kinds random boards do not have (texts on copper, every kind of drawing, footprints turned off square, arc tracks,
  blind vias, plated and unplated holes, a custom pad, a footprint's zone, a rule area) and filled polygons with spikes
  sharper and blunter than the sliver check's limit, then `drc.py` on it. `Tests/KiCadRouterTests/Fixtures/copper`
  holds `drawn` (`--draw`), and the boards of `Fixtures/boards` have theirs too.
- `thermals.py`: a board of thermal reliefs for `DRCTests`' starved thermals (`thermals.py OUT.kicad_pcb [SEED]`):
  pads of a zone's net in its fill (filled by KiCad's zone filler), their spokes cut off by tracks of other nets and
  the board's edge, the board asking three spokes of each; pads joined solidly or not at all by the pad or its
  footprint, pads with thermal gaps of their own, plated holes in a zone that relieves them only, spokes drawn by
  hand (a track, a copper drawing), a custom pad with spoke templates, pads with spokes into islands that touch
  nothing else, and pads at random places among random tracks; then `drc.py` on it.
  `Tests/KiCadRouterTests/Fixtures/thermals` holds `drawn` (`thermals.py ... 7`).
- `texts.py`: KiCad's texts of boards (`texts.py BOARD.kicad_pcb...`): each board text's, footprint field's and
  footprint text's shape as KiCad's DRC takes it (`PCB_TEXT::GetEffectiveShape`, through KiCad's `pcbnew` module: the
  KiCad font's strokes, each a segment of the text's pen width), its pen width, text box (`EDA_TEXT::GetTextBox`) and
  bounding box (`PCB_TEXT::GetBoundingBox`), the text it shows and whether it is shown, next to the board as
  `BOARD.texts` (JSON), by uuid. `TextTests` checks the port's (`BoardWorld.textStrokes`) against it, segment for
  segment. With `--draw OUT.kicad_pcb`, a board of texts made to take KiCad's text drawing down the ways random boards
  do not (every justification, mirrored or not, at angles on and off the axes; several lines and their spacing; bold,
  italic, pen widths worked out or clamped; overbars, subscripts, superscripts, links, tabs, escapes, characters the
  font does not have, empty and blank texts; footprints turned and flipped, their texts kept upright or not, showing
  `${REFERENCE}` and the like, some hidden; a knockout text and one in another font, which the port does not make).
  `Tests/KiCadRouterTests/Fixtures/texts` holds `drawn` (`--draw`).
- `newstroke.py`: writes `Sources/KiCadRouter/StrokeFontData.swift`, the KiCad font's glyphs, from KiCad's
  `common/newstroke_font.cpp` (`newstroke.py KICAD/common/newstroke_font.cpp OUT.swift`).
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
  With `--mode drag`, drags instead, on boards like the shove mode's with more tracks on them: of a track's segment
  (grabbed along it), its corner (within half its width of its end, or on it) or a via, now and then at free angles,
  walking round what is in their way, shoving it or marking it; the pointer taken mostly to another net's track or via
  near by (into it, or a little past it), now and then near a corner of the dragged net's own, where the drag snaps to
  it, and back, now and then resting, and clicked to keep the drag (now and then with Ctrl, to keep it whatever it
  collides with); each drag chosen on the board as the drags before it left it (KiCad's router run on those first), so
  that a track dragged can be dragged again. `--shoving` keeps the boards on which a drag shoved another net's track
  or via aside; `--boards` drags tracks and vias of real boards.
  `kicad-drag-routes.json` is
  `scenes.py --mode drag --shoving ... ../../Tests/KiCadRouterTests/Fixtures/kicad-drag-routes.json 40 20261026`,
  and `kicad-board-drag-routes.json`
  `scenes.py --mode drag --boards ... 2 20261026 ../../Tests/KiCadRouterTests/Fixtures/boards/*.json`.
  With `--mode diffpair`, differential pairs instead, on boards with pairs' nets (USB_D+ and USB_D-, LVDS0_P and
  LVDS0_N, CLK_P1 and CLK_N1...) and others (one named as a pair's, its partner missing): a pad of each of a pair's
  nets side by side, the same shape, at each end of where the pair goes (two ends or three; every kind of pad, surface
  mount and through-hole), some with a pair of tracks out of them that end short, now and then a pair of its vias;
  tracks of other nets across the way, and pads, tracks and vias as the shove mode's. Each pair starts on a pad, via
  or track end of a pair's net (now and then of another net, or on nothing, which KiCad refuses), walks round, shoves
  or marks, at a random width and gap (now and then a board minimum clearance over the gap, which KiCad refuses too);
  the pointer goes to another pair of its pads, or its tracks' ends (its last move with the pad under it), or
  anywhere, with vias placed (now and then the sizes given again with them), parts fixed, undo, posture flips and
  layer switches on the way; each chosen on the board as the pairs before it left it (KiCad's router run on those
  first), so that a pair fixed short is gone on from. `--shoving` keeps the boards on which a pair shoved another
  net's track or via aside; `--boards` routes pairs on real boards. `kicad-diffpair-routes.json` is
  `scenes.py --mode diffpair --shoving ... ../../Tests/KiCadRouterTests/Fixtures/kicad-diffpair-routes.json 30 20261027`,
  and `kicad-board-diffpair-routes.json`
  `scenes.py --mode diffpair --boards ... 2 20261030 ../../Tests/KiCadRouterTests/Fixtures/pairboards/*.json`.
  With `--arcs`, boards with arc tracks too (on their own or out of a pad, of an eighth of a turn to three; the shove
  and drag modes' tracks with some of their turns rounded by arcs), routes that start on an arc (at an end, or on its
  middle) or go to one of their net, and drags that grab an arc by its middle
  (KiCad drags the arc itself, keeping it tangent to the tracks either side, a stub put at a free end) and pull it
  out or push it in; with `--rounded`, each route in a corner mode of its own, rounded ones twice as often as mitred.
  Both go with every mode and with `--boards`. `kicad-arc-routes.json` is
  `scenes.py --arcs --rounded --mode mix ... ../../Tests/KiCadRouterTests/Fixtures/kicad-arc-routes.json 30 20261101`,
  `kicad-arc-drag-routes.json`
  `scenes.py --arcs --mode drag --shoving ... ../../Tests/KiCadRouterTests/Fixtures/kicad-arc-drag-routes.json 25 20261101`,
  and on boards with arc tracks `kicad-board-arc-routes.json`
  `scenes.py --arcs --rounded --mode mix --boards ... 2 20261103 ../../Tests/KiCadRouterTests/Fixtures/arcboards/*.json`
  and `kicad-board-arc-drag-routes.json`
  `scenes.py --arcs --mode drag --boards ... 2 20261103 ../../Tests/KiCadRouterTests/Fixtures/arcboards/*.json`.
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
  in the order of their places rather than of a hash map's; the coupled net's items a differential pair could start
  or end on are taken in the order they were made, so that of two the same distance away the first is the one the pair
  goes from, rather than in a set of pointers' order (the port does all four in the same order); a start
  pad's board item is asked its type only when it has one; and why a route cannot start on a non-routable item (a
  hole with no plating, a rule area, a text), which KiCad asks the item's board item, is asked of `router.cpp` when
  there is none. Where the line placer reads an arc as a segment, which is undefined, it says so, and the program
  stops (exit status 3). The dot product `DRAGGER::startDragArc` takes to choose which way the stub it puts at an
  arc's free end goes overflows its ints for an arc of more than some 46 µm radius, which is undefined too, but
  KiCad's builds wrap it round in 32 bits, the same every time, and nearly every drag of an arc at a line's end comes
  to it: it is made to wrap round in unsigned ints, which C++ defines, as the port wraps it.
- `stubs.cpp`: what the router and KiCad's settings call from the rest of KiCad, as these programs need it (no
  program object, no settings folder, no boards), the hook `router.cpp` answers that last question through, and the
  stop where KiCad's router would do what is undefined (`kicadReferenceUndefined`).

With `KICAD_ROUTER_DEBUG` set, `router.cpp` writes KiCad's router debug messages to standard error, and the router
tests write the port's in the same form, to compare the two where a route differs.

`BoardRoutingTests.swift` goes one step further, with KiCad's own design rules check as the judge: it routes pads of
the same net on real boards with `BoardRouter` (the port, on the board's world, writing what it places into the
board file), and runs `kicad-cli pcb drc` on the result; no clearance, crossing, short or size violation may
involve a track or via the router placed. `BoardEditingTests.swift` does the same with tracks and vias dragged on
the fixture boards (`BoardEditing`'s drag), walking round and shoving: no clearance, crossing or short with them; and
with differential pairs routed on the pair boards (`BoardEditing`'s `startPair`, as the router tool's Route
Differential Pair starts one, at the net class's diff pair width and gap), walking round through vias and shoving.
`BoardRoutingTests` routes the arc boards too (`Fixtures/arcboards`), each route in a corner mode of its own,
rounded ones among them: the arcs the port puts on go into the board file as KiCad writes arc tracks (start, mid,
end, width, layer, net, uuid), and KiCad's DRC reads them and finds nothing wrong with them.

CI (`.github/workflows/kicad.yml`) builds them and checks the port against 2000 geometry cases of each kind (with
arcs too), 2000 clipper cases of each kind, 1000 random router boards, 400 random boards with routes that shove, 400
random boards with tracks and vias dragged, 100 random boards with differential pairs, 200 random boards with arc
tracks and routes in every corner mode, 150 with arc tracks and drags, 60 real boards made by `boards.py` (their
worlds, routes on them that walk round, mark and shove, drags on them, and KiCad's DRC on the port's routes), 10
with pairs (`boards.py --pairs`, pairs routed on them) and 20 with arc tracks (`boards.py --arcs`: their worlds,
routes in every corner mode and drags on them); each run has a new seed, the run number, which the names a failure
reports carry.
