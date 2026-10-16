# KiCad's code in JSpice for macOS

JSpice for macOS works with [KiCad](https://www.kicad.org) for its printed circuit boards, and some of its code is
KiCad's: brought over from KiCad's C++ to Swift, or generated from KiCad's files. KiCad is free software under the
GNU General Public License, version 3 or (at your option) any later version, and so is the code here that comes from
it. JSpice itself is under the GNU General Public License version 3, so the two go together, but the parts listed
below cannot be offered under the other licenses Knowm offers JSpice under (see `../LICENSE`): they are KiCad's
authors' work as much as ours, and only the GPL covers them.

KiCad's copyright: Copyright The KiCad Developers, see KiCad's
[AUTHORS.txt](https://gitlab.com/kicad/code/kicad/-/blob/master/AUTHORS.txt) (and, for some of the files, Copyright
CERN). Each of these files names the KiCad sources it comes from, from KiCad 10.0.7.

| Here | From KiCad |
| --- | --- |
| `Sources/KiCadRouter/` (the board editor's router: geometry, collisions, hulls, and the router on them) | `libs/kimath` (`seg`, `shape_line_chain`, `shape_collisions`, `shape_nearest_points`, `shape_rect`, `shape_arc`, `circle`, `shape_index`, `direction_45`, `vector2d`, `eda_angle`, `util`, `trigo`, `geometry_utils`, `convert_basic_shapes_to_polygon`), `thirdparty/rtree` (KiCad's R-tree) and `pcbnew/router` (`pns_item`, `pns_node`, `pns_index`, `pns_joint`, `pns_line`, `pns_segment`, `pns_via`, `pns_solid`, `pns_hole`, `pns_utils`, `pns_topology`, `pns_walkaround`, `pns_optimizer`, `pns_mouse_trail_tracer`, `pns_line_placer`, `pns_router`, `pns_routing_settings`, `pns_sizes_settings`), and for the router on a real board (`World.swift`, `BoardWorld.swift`, `BoardRouter.swift`, `BoardEditing.swift`) `pcbnew/router/pns_kicad_iface.cpp` (`SyncWorld`, `PNS_PCBNEW_RULE_RESOLVER`, `ImportSizes`), `pcbnew/router/router_tool.cpp` (how its tool drives it), `pcbnew/drc/drc_engine.cpp` (its implicit rules), `common/netclass.cpp` and `common/project/net_settings.cpp` (effective net classes), `pcbnew/pad.cpp`, `pcbnew/pcb_shape.cpp` and `common/eda_shape.cpp` (pads' and drawings' shapes) |
| `Sources/KiCadKit/NetlistUpdater.swift` (a board brought up to date with the schematic) | `pcbnew/netlist_reader/board_netlist_updater.cpp` |
| `Sources/KiCadKit/Connectivity.swift` (what touches what in a board's copper, and its ratsnest) | `pcbnew/connectivity` |
| `Sources/KiCadKit/SExpression.swift` (boards written as KiCad writes them) | `common/io/kicad/kicad_io_utils.cpp` (`KICAD_FORMAT::Prettify`) |
| `Sources/KiCadKit/Board.swift` (footprints placed, turned and flipped as KiCad does it) | `pcbnew/footprint.cpp`, `pcbnew/pad.cpp` |
| `Sources/KiCadLink/Generated/` (KiCad's API messages) | `api/proto`, through `protoc` (`tools/kicad-api/generate.sh`) |
| `tools/kicad-reference/` (programs that link KiCad's own code, to check the router against it; `patch.py` changes two places in KiCad's router before it is built; `board-scene.py` follows `SyncWorld` and the rule resolver through KiCad's Python module) | links `libs/kimath`, `pcbnew/router` and parts of `common` |

KiCad's source code is at <https://gitlab.com/kicad/code/kicad>; KiCad 10.0.7's is its tag `10.0.7`.
