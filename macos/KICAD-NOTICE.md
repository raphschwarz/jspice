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
| `Sources/KiCadRouter/` (the board editor's router: geometry, collisions, hulls, and the router on them) | `libs/kimath` (`shape_poly_set` (simplifying, fracturing and triangulating a zone's outline), `polygon_triangulation`, `vertex_set`, `seg`, `shape_line_chain`, `shape_collisions`, `shape_nearest_points`, `shape_rect`, `shape_arc`, `circle`, `shape_index`, `direction_45`, `vector2d`, `eda_angle`, `util`, `trigo`, `geometry_utils`, `convert_basic_shapes_to_polygon`, `arc_chord_params`), `thirdparty/rtree` (KiCad's R-tree) and `pcbnew/router` (`pns_item`, `pns_node`, `pns_index`, `pns_joint`, `pns_line`, `pns_segment`, `pns_arc`, `pns_via`, `pns_solid`, `pns_hole`, `pns_utils`, `pns_topology`, `pns_walkaround`, `pns_shove`, `pns_optimizer`, `pns_mouse_trail_tracer`, `pns_placement_algo`, `pns_line_placer`, `pns_diff_pair`, `pns_diff_pair_placer`, `ranged_num`, `pns_drag_algo`, `pns_dragger`, `pns_meander`, `pns_meander_placer_base`, `pns_meander_placer`, `pns_dp_meander_placer`, `pns_meander_skew_placer` (length tuning: `Meander.swift`, `MeanderPlacer.swift`, `DPMeanderPlacer.swift`), `pns_router`, `pns_routing_settings`, `pns_sizes_settings`), `pcbnew/router/pns_kicad_iface.cpp` (`CalculateRoutedPathLength`) and `pcbnew/length_delay_calculation/length_delay_calculation.cpp` (`CalculateLengthDetails`, `StackupHeight`: a tuned path's length), `pcbnew/board_stackup_manager/board_stackup.cpp` (`BuildDefaultStackupList`, `GetLayerDistance`: a via's height, `Stackup.swift`) with the stackup as `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp` reads it (`parseBoardStackup`), and for the router on a real board (`World.swift`, `BoardWorld.swift`, `BoardRouter.swift`, `BoardEditing.swift`) `pcbnew/router/pns_kicad_iface.cpp` (`SyncWorld`, `PNS_PCBNEW_RULE_RESOLVER`, `ImportSizes`), `pcbnew/board.cpp` (`MatchDpSuffix`, `DpCoupledNet`: which nets are differential pairs), `pcbnew/router/router_tool.cpp` and `pns_tool_base.cpp` (how its tool drives it, routing and dragging), `pcbnew/generators/pcb_tuning_pattern.cpp` (how its tuning patterns drive it, tuning lengths), `pcbnew/tools/pcb_grid_helper.cpp` and `common/tool/grid_helper.cpp` (where the pointer snaps to a track or arc), `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp` and `pcbnew/pcb_track.cpp` (tracks, arc tracks and vias as KiCad writes them), `pcbnew/drc/drc_engine.cpp` (its implicit rules), `common/netclass.cpp` and `common/project/net_settings.cpp` (effective net classes), `pcbnew/pad.cpp`, `pcbnew/pcb_shape.cpp` and `common/eda_shape.cpp` (pads' and drawings' shapes, custom pads' merged outlines), `pcbnew/zone.cpp` and `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp` (a zone's outline as KiCad reads it), and `libs/kimath`'s `roundrect` and `shape_utils` (a rectangle's rounded corners); for its design rules check (`DRC.swift`, `DRCClearance.swift`, `DRCEdge.swift`, `DRCConnectivity.swift`, `DRCKeepout.swift`, `DRCCourtyard.swift`, `DRCSolderMask.swift`, `DRCZoneConnections.swift`, `DRCOutline.swift`, `DRCSilk.swift`, `DRCReport.swift`, `DRCSliver.swift`) `pcbnew/drc` (`drc_engine` (its implicit rules, how a check's rule is resolved, net ties), `drc_test_provider` and the providers of the checks it makes: `drc_test_provider_track_width`, `_via_diameter`, `_hole_size`, `_annular_width`, `_hole_to_hole`, `_copper_clearance`, `_edge_clearance` (copper and silkscreen against the board's edges), `_connectivity`, `_disallow` (keepouts), `_courtyard_clearance`, `_solder_mask` (mask bridges, and silkscreen against the whole mask), `_silk_clearance` (silkscreen against silkscreen and the mask's openings), `_zone_connections` (starved thermal reliefs), `_misc` (`testOutline`: the board's outline), `_sliver_checker` (copper slivers, each layer's copper made by `forEachGeometryItem`'s order, `EDA_SHAPE::TransformShapeToPolygon`, `PCB_TRACK::TransformShapeToPolygon` and `PCB_TEXT::TransformShapeToPolygon`); `pcbnew/pcbexpr_functions.cpp` (`intersectsKeepout`: what a keepout area keeps out); `drc_cache_generator` and `drc_rtree` (the copper items' R-tree, and the silkscreen's and its targets', `QueryCollidingPairs`), `drc_item`), `pcbnew/board.cpp` (`UpdateBoardOutline`: the outline the silkscreen checks go by; `FillItemMap`: the items KiCad's report names), `pcbnew/pad.cpp`, `pcbnew/pcb_track.cpp`, `pcbnew/pcb_shape.cpp`, `pcbnew/pcb_text.cpp`, `pcbnew/zone.cpp` and `common/eda_shape.cpp` (items' shapes on the silkscreen and mask layers, their boxes, `TransformShapeToPolygon`, `TransformTextToPolySet`), `common/rc_item.cpp` and the items' `GetItemDescription`s (the items as KiCad's report describes them), `pcbnew/footprint.cpp` (net tie pad groups), `pcbnew/convert_shape_list_to_polygon.cpp` (`TestBoardOutlinesGraphicItems`, `BuildBoardPolygonOutlines`: the board's outline of its and its footprints' drawings), `pcbnew/board.cpp` and `pcbnew/footprint.cpp` (`Visit`: the order the board's drawings are collected in), `pcbnew/connectivity` (`connectivity_algo`, `connectivity_items`, `connectivity_data`: what touches what, its clusters, the nets propagated through them, dangling ends, a zone's isolated islands and those that touch one item only) and `pcbnew/ratsnest/ratsnest_data.cpp` (each net's missing connections), `pcbnew/board_design_settings.cpp` (the rules' defaults and severities) and `common/eda_units.cpp` (values as its messages give them); for footprints' courtyards (`Outlines.swift`, `Courtyards.swift`) `pcbnew/convert_shape_list_to_polygon.cpp` (`ConvertOutlineToPolygon`: drawings chained into outlines with holes), `pcbnew/footprint.cpp` (`BuildCourtyardCaches`) and `libs/kimath`'s `bezier_curves` (a curve's points); for texts in the KiCad font (`StrokeFont.swift`, `Texts.swift`) `common/font` (`stroke_font`, `glyph`, `font`: the stroke font, its glyphs placed, lines, markup and boxes), `include/font/font_metrics.h`, `common/markup_parser.cpp` (overbars, subscripts, superscripts, links), `common/callback_gal.cpp` (a glyph's segments), `common/eda_text.cpp` (`GetEffectiveTextShape`, `GetTextBox`, `GetEffectiveTextPenWidth`), `common/gr_text.cpp` (pen widths), `pcbnew/pcb_text.cpp` and `pcbnew/pcb_field.cpp` (`GetShownText`, `GetDrawRotation`, `GetBoundingBox`, `GetEffectiveShape`), `pcbnew/footprint.cpp` (`ResolveTextVar`), `common/common.cpp` (`ExpandTextVars`, `ResolveTextVars`), `common/string_utils.cpp` (`UnescapeString`) and `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp` (a text as KiCad reads it); for its via placer (`ViaPlacer.swift`) `pcbnew/tools/drawing_tool.cpp` (`VIA_PLACER`: where KiCad's Add Vias puts a via, its net, the design rules it keeps); for texts and footprints placed on their own (`BoardPlacing.swift`) `pcbnew/tools/drawing_tool.cpp` (`PlaceText`: a new text's style), `pcbnew/board_design_settings.cpp` (the text defaults of each class of layer, `GetLayerClass`), `include/gr_text.h` (`InferBold`), `pcbnew/tools/board_editor_control.cpp` (`PlaceFootprint`) and `pcbnew/load_select_footprint.cpp` (`loadFootprint`), with texts as `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp` writes them; for its box selection (`BoxSelection.swift`) `pcbnew/tools/pcb_selection_tool.cpp` (`SelectMultiple`: what a box drawn left to right or right to left takes), the items' `HitTest`s in `pcbnew/pcb_track.cpp`, `pcbnew/footprint.cpp` (with `GetBoundingBox`), `pcbnew/pad.cpp`, `pcbnew/zone.cpp` and `common/eda_shape.cpp` (with `getBoundingBox` and `computeArcBBox`), and `libs/kimath`'s `box2.h` and `trigo` (`SegmentIntersectsSegment`); for its zone filler (`ZoneFiller.swift`, `ZoneFillerCopper.swift`, `PolySetFill.swift`) `pcbnew/zone_filler.cpp` (`ZONE_FILLER::Fill`: copper and non-copper fills, thermal reliefs and spokes, clearances, keepouts, higher-priority zones, minimum width pruning, hatching, island removal, the iterative refill; its `VERTEX_CONNECTOR`), `pcbnew/zone.cpp` (`BuildSmoothedPoly`, `GetInteractingZones`, `HigherPriority`, `TransformShapeToPolygon`), `pcbnew/zone_settings.cpp` and `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp` (a zone's settings as read), `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp` (its fill as written), `pcbnew/drc/drc_engine.cpp` (`EvalRules` and `EvalZoneConnection` for the filler's constraints), `pcbnew/connectivity/connectivity_algo.cpp` (`FillIsolatedIslandsMap`), `pcbnew/board.cpp` (`GetBoardPolygonOutlines`, `ComputeBoundingBox`), `pcbnew/pad.cpp`, `pcbnew/pcb_track.cpp` and `pcbnew/pcb_text.cpp` (items' polygons, boxes and overrides), and `libs/kimath`'s `shape_poly_set` (`Deflate`, `Area`, `Contains`, `Unfracture`, `InflateWithLinkedHoles`, `Chamfer`, `Fillet`), `corner_operations`, `vertex_set` and `convex_hull`; for its teardrops (`Teardrops.swift`) `pcbnew/teardrop` (`teardrop.cpp`, `teardrop_utils.cpp`, `teardrop_parameters.cpp`, `teardrop.h` and `teardrop_parameters.h`: `TEARDROP_MANAGER` and its settings), `pcbnew/dialogs/dialog_global_edit_teardrops.cpp` (the settings set as its Set Teardrops dialog sets them), `pcbnew/board_design_settings.cpp` (the board's teardrop settings in its project), `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp` and `pcb_io_kicad_sexpr.cpp` (pads' and vias' teardrop settings and teardrop zones as read and written, and the order zones are written in), `pcbnew/pad.cpp` and `pcbnew/pcb_track.cpp` (hit tests, lengths), `pcbnew/drc/drc_rtree.h` (`CheckColliding`), `common/kiid.cpp` (`KIID::Combine`) and `libs/kimath`'s `convex_hull`, `trigo` (`TestSegmentHit`), `shape_poly_set` (`Collide`) and `bezier_curves`; and the stroke font's glyphs (`StrokeFontData.swift`, generated by `tools/kicad-reference/newstroke.py`) from `common/newstroke_font.cpp`, which has notices of its own (below) |
| `Sources/KiCadKit/NetlistUpdater.swift` (a board brought up to date with the schematic) | `pcbnew/netlist_reader/board_netlist_updater.cpp` |
| `Sources/KiCadKit/Connectivity.swift` (what touches what in a board's copper, and its ratsnest) | `pcbnew/connectivity` |
| `Sources/KiCadKit/SExpression.swift` (boards written as KiCad writes them) | `common/io/kicad/kicad_io_utils.cpp` (`KICAD_FORMAT::Prettify`) |
| `Sources/KiCadKit/Board.swift` (footprints placed, turned and flipped as KiCad does it) | `pcbnew/footprint.cpp`, `pcbnew/pad.cpp` |
| `Sources/KiCadLink/Generated/` (KiCad's API messages) | `api/proto`, through `protoc` (`tools/kicad-api/generate.sh`) |
| `tools/kicad-reference/` (programs that link KiCad's own code, to check the router against it; `patch.py` changes a few places in KiCad's router before it is built, so it answers the same each run and needs no board items behind its own; `board-scene.py` follows `SyncWorld` and the rule resolver through KiCad's Python module) | links `libs/kimath`, `pcbnew/router` and parts of `common` |

KiCad's source code is at <https://gitlab.com/kicad/code/kicad>; KiCad 10.0.7's is its tag `10.0.7`.

## Clipper2

`Sources/KiCadRouter/Clipper*.swift` (the polygon clipper: boolean operations and offsets) come from Clipper2, by
Angus Johnson, as KiCad 10.0.7 ships it (`thirdparty/clipper2`): Copyright Angus Johnson 2010-2026, under the Boost
Software License 1.0 rather than the GPL:

> Boost Software License - Version 1.0 - August 17th, 2003
>
> Permission is hereby granted, free of charge, to any person or organization obtaining a copy of the software and
> accompanying documentation covered by this license (the "Software") to use, reproduce, display, distribute,
> execute, and transmit the Software, and to prepare derivative works of the Software, and to permit third-parties to
> whom the Software is furnished to do so, all subject to the following:
>
> The copyright notices in the Software and this entire statement, including the above license grant, this
> restriction and the following disclaimer, must be included in all copies of the Software, in whole or in part, and
> all derivative works of the Software, unless such copies or derivative works are solely in the form of
> machine-executable object code generated by a source language processor.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
> WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
> COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN
> CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
> THE SOFTWARE.

## delaunator-cpp

`Sources/KiCadRouter/Delaunator.swift` (the Delaunay triangulation the ratsnest is made from) comes from
delaunator-cpp (https://github.com/abellgithub/delaunator-cpp, after Mapbox's Delaunator) as KiCad 10.0.7 ships it
(`thirdparty/delaunator`), under the MIT license rather than the GPL:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
> rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
> permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of
> the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
> WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
> COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
> OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## nanoflann

The KD-tree in `Sources/KiCadRouter/Outlines.swift` (`KDTree`: how KiCad finds the drawings' ends nearest a point as
it chains a courtyard's outline) comes from nanoflann (https://github.com/jlblancoc/nanoflann) as KiCad 10.0.7 ships
it (`thirdparty/nanoflann`), under the BSD license rather than the GPL:

> Copyright 2008-2009 Marius Muja (mariusm@cs.ubc.ca). All rights reserved.
> Copyright 2008-2009 David G. Lowe (lowe@cs.ubc.ca). All rights reserved.
> Copyright 2011-2025 Jose Luis Blanco (joseluisblancoc@gmail.com). All rights reserved.
>
> Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
> following conditions are met:
>
> 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following
>    disclaimer.
> 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
>    following disclaimer in the documentation and/or other materials provided with the distribution.
>
> THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
> TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
> THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
> BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
> INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
> (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
> POSSIBILITY OF SUCH DAMAGE.

## newstroke

`Sources/KiCadRouter/StrokeFontData.swift` (the glyphs of the KiCad font, newstroke) is generated from KiCad 10.0.7's
`common/newstroke_font.cpp` (by `tools/kicad-reference/newstroke.py`): Copyright (C) 2010 vladimir uryvaev
<vovanius@bk.ru>; Copyright The KiCad Developers, under the GNU General Public License, version 2 or (at your option)
any later version. Its CJK ideographs come with these notices of their own, as that file has them:

> Modified 2019 to include based CJK Unicode Ideographs, using
> code copyright (c) 2018 Lingdong Huang
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.
>
> Font used for CJK is Source Han Sans from https://github.com/adobe-fonts/source-han-sans
> Source Han Sans is Copyright 2014-2019 Adobe (http://www.adobe.com/), with Reserved Font
> Name 'Source'. Source is a trademark of Adobe in the United States
> and/or other countries.
>
> This Font Software is licensed under the SIL Open Font License,
> Version 1.1.
>
> This license is copied below, and is also available with a FAQ at:
> http://scripts.sil.org/OFL
>
> -----------------------------------------------------------
> SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
> -----------------------------------------------------------
>
> PREAMBLE
> The goals of the Open Font License (OFL) are to stimulate worldwide
> development of collaborative font projects, to support the font
> creation efforts of academic and linguistic communities, and to
> provide a free and open framework in which fonts may be shared and
> improved in partnership with others.
>
> The OFL allows the licensed fonts to be used, studied, modified and
> redistributed freely as long as they are not sold by themselves. The
> fonts, including any derivative works, can be bundled, embedded,
> redistributed and/or sold with any software provided that any reserved
> names are not used by derivative works. The fonts and derivatives,
> however, cannot be released under any other type of license. The
> requirement for fonts to remain under this license does not apply to
> any document created using the fonts or their derivatives.
>
> DEFINITIONS
> "Font Software" refers to the set of files released by the Copyright
> Holder(s) under this license and clearly marked as such. This may
> include source files, build scripts and documentation.
>
> "Reserved Font Name" refers to any names specified as such after the
> copyright statement(s).
>
> "Original Version" refers to the collection of Font Software
> components as distributed by the Copyright Holder(s).
>
> "Modified Version" refers to any derivative made by adding to,
> deleting, or substituting -- in part or in whole -- any of the
> components of the Original Version, by changing formats or by porting
> the Font Software to a new environment.
>
> "Author" refers to any designer, engineer, programmer, technical
> writer or other person who contributed to the Font Software.
>
> PERMISSION & CONDITIONS
> Permission is hereby granted, free of charge, to any person obtaining
> a copy of the Font Software, to use, study, copy, merge, embed,
> modify, redistribute, and sell modified and unmodified copies of the
> Font Software, subject to the following conditions:
>
> 1) Neither the Font Software nor any of its individual components, in
> Original or Modified Versions, may be sold by itself.
>
> 2) Original or Modified Versions of the Font Software may be bundled,
> redistributed and/or sold with any software, provided that each copy
> contains the above copyright notice and this license. These can be
> included either as stand-alone text files, human-readable headers or
> in the appropriate machine-readable metadata fields within text or
> binary files as long as those fields can be easily viewed by the user.
>
> 3) No Modified Version of the Font Software may use the Reserved Font
> Name(s) unless explicit written permission is granted by the
> corresponding Copyright Holder. This restriction only applies to the
> primary font name as presented to the users.
>
> 4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
> Software shall not be used to promote, endorse or advertise any
> Modified Version, except to acknowledge the contribution(s) of the
> Copyright Holder(s) and the Author(s) or with their explicit written
> permission.
>
> 5) The Font Software, modified or unmodified, in part or in whole,
> must be distributed entirely under this license, and must not be
> distributed under any other license. The requirement for fonts to
> remain under this license does not apply to any document created using
> the Font Software.
>
> TERMINATION
> This license becomes null and void if any of the above conditions are
> not met.
>
> DISCLAIMER
> THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
> EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
> MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
> OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
> COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
> INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
> DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
> FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
> OTHER DEALINGS IN THE FONT SOFTWARE.
