# KiCad reference

The tools used to check JSpice's board router (`Sources/KiCadRouter`, ported from KiCad's) against KiCad's own code:
programs linked with KiCad 10.0.7's geometry library (`libs/kimath`) and its PCB editor's router (`pcbnew/router`),
compiled from KiCad's sources as they are. They link KiCad's code, so they are under KiCad's license, the GNU General
Public License version 3 or later (see `../../KICAD-NOTICE.md`).

- `build.sh`: fetches the parts of KiCad's sources these need from KiCad's GitLab, compiles them (with a C++20
  compiler, wxWidgets 3.2 and Boost's headers: on Ubuntu, `g++ libwxgtk3.2-dev libboost-dev`) and builds the
  programs. With no argument it writes the router tests' fixture; with a number, a set of that many cases of each kind
  for `KICAD_GEOMETRY_REFERENCE`.
- `geometry.cpp`: random cases, chosen to reach the corners (segments along the 45° directions or nearly, touching,
  overlapping, of no length; chains that share points; shapes close together), with KiCad's answers for them: vector
  lengths and resizing, `rescale`, segment distances, intersections and collisions, `DIRECTION_45` and the traces it
  starts, line chain simplification, splitting, intersections, inside tests and collisions, shape against shape
  collisions with their distances, and the router's hulls (`BuildHullForPrimitiveShape`) and where paths cross them
  (`HullIntersection`). `GeometryTests.swift` checks the port gives the same answers, to the nanometre.
- `stubs.cpp`: what the router and KiCad's settings call from the rest of KiCad, as these programs need it (no
  program object, no settings folder, no boards).

CI (`.github/workflows/kicad.yml`) builds them and checks the port against 2000 cases of each kind.
