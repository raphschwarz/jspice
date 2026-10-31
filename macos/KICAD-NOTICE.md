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
| `Sources/KiCadRouter/` (the board editor's router: geometry, collisions, hulls, and the router on them) | `libs/kimath` (`shape_poly_set` (simplifying, fracturing and triangulating a zone's outline), `polygon_triangulation`, `vertex_set`, `seg`, `shape_line_chain`, `shape_collisions`, `shape_nearest_points`, `shape_rect`, `shape_arc`, `circle`, `shape_index`, `direction_45`, `vector2d`, `eda_angle`, `util`, `trigo`, `geometry_utils`, `convert_basic_shapes_to_polygon`, `arc_chord_params`), `thirdparty/rtree` (KiCad's R-tree) and `pcbnew/router` (`pns_item`, `pns_node`, `pns_index`, `pns_joint`, `pns_line`, `pns_segment`, `pns_arc`, `pns_via`, `pns_solid`, `pns_hole`, `pns_utils`, `pns_topology`, `pns_walkaround`, `pns_shove`, `pns_optimizer`, `pns_mouse_trail_tracer`, `pns_placement_algo`, `pns_line_placer`, `pns_diff_pair`, `pns_diff_pair_placer`, `ranged_num`, `pns_drag_algo`, `pns_dragger`, `pns_component_dragger` (a footprint dragged with its tracks: `ComponentDragger.swift`), `pns_multi_dragger` (several tracks dragged together: `MultiDragger.swift`), `pns_meander`, `pns_meander_placer_base`, `pns_meander_placer`, `pns_dp_meander_placer`, `pns_meander_skew_placer` (length tuning: `Meander.swift`, `MeanderPlacer.swift`, `DPMeanderPlacer.swift`), `pns_router`, `pns_routing_settings`, `pns_sizes_settings`), `pcbnew/router/pns_kicad_iface.cpp` (`CalculateRoutedPathLength`) and `pcbnew/length_delay_calculation/length_delay_calculation.cpp` (`CalculateLengthDetails`, `StackupHeight`, `inferViaInPad`: a tuned path's length; `OptimiseTraceInPad`, `clipLineToPad`, `findArcPadIntersection`, `OptimiseTraceInVia`, `clipLineToVia`: its lines cut to the copper of the pads and vias they end in), `pcbnew/board_stackup_manager/board_stackup.cpp` (`BuildDefaultStackupList`, `GetLayerDistance`: a via's height, `Stackup.swift`) with the stackup as `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp` reads it (`parseBoardStackup`), and for the router on a real board (`World.swift`, `BoardWorld.swift`, `BoardRouter.swift`, `BoardEditing.swift`, `BoardFootprintDrag.swift`, `BoardMultiDrag.swift`) `pcbnew/router/pns_kicad_iface.cpp` (`SyncWorld`, `PNS_PCBNEW_RULE_RESOLVER`, `ImportSizes`, and `Commit`, `UpdateItem` and `RemoveItem`: a dragged footprint moved by its pads' offset), `pcbnew/board.cpp` (`MatchDpSuffix`, `DpCoupledNet`: which nets are differential pairs), `pcbnew/router/router_tool.cpp` and `pns_tool_base.cpp` (how its tool drives it, routing, dragging, and dragging footprints and tracks selected together: `InlineDrag`), `pcbnew/generators/pcb_tuning_pattern.cpp` and `.h` (how its tuning patterns drive it, tuning lengths; and the patterns themselves, kept in the board: `TuningPatterns.swift`, `TuningPatternGenerator.swift`, `TuningPatternEditing.swift`: their properties, outline and base lines, `EditStart`, `Update`, `EditFinish`, `EditCancel`, `Remove`, `CreateNew` and the Tune Length tool's `PlaceTuningPattern`), `pcbnew/pcb_generator.cpp`, `pcbnew/tools/generator_tool.cpp` and `generator_tool_pns_proxy.cpp` (the generator tool and the changes its router keeps), `pcbnew/tools/pcb_point_editor.cpp` and `edit_tool.cpp` (a pattern's end dragged, a pattern deleted), `pcbnew/board_commit.cpp` (a removed item leaves its group), `include/string_any_map.h` and `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp` and `pcb_io_kicad_sexpr_parser.cpp` (a generator as KiCad writes and reads it), `pcbnew/router/pns_kicad_iface.cpp` (`syncTrack`, `syncArc`, `syncVia`: a generator's tracks locked), `libs/kimath`'s `shape_poly_set` (`OffsetLineChain`) and `shape_line_chain` (`OffsetLine`), `pcbnew/tools/pcb_grid_helper.cpp` and `common/tool/grid_helper.cpp` (where the pointer snaps to a track or arc), `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp` and `pcbnew/pcb_track.cpp` (tracks, arc tracks and vias as KiCad writes them), `pcbnew/drc/drc_engine.cpp` (its implicit rules), `common/netclass.cpp` and `common/project/net_settings.cpp` (effective net classes), `pcbnew/pad.cpp`, `pcbnew/pcb_shape.cpp` and `common/eda_shape.cpp` (pads' and drawings' shapes, custom pads' merged outlines), `pcbnew/zone.cpp` and `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp` (a zone's outline as KiCad reads it), and `libs/kimath`'s `roundrect` and `shape_utils` (a rectangle's rounded corners); for its design rules check (`DRC.swift`, `DRCClearance.swift`, `DRCEdge.swift`, `DRCConnectivity.swift`, `DRCKeepout.swift`, `DRCCourtyard.swift`, `DRCSolderMask.swift`, `DRCZoneConnections.swift`, `DRCOutline.swift`, `DRCSilk.swift`, `DRCReport.swift`, `DRCSliver.swift`) `pcbnew/drc` (`drc_engine` (its implicit rules, how a check's rule is resolved, net ties), `drc_test_provider` and the providers of the checks it makes: `drc_test_provider_track_width`, `_via_diameter`, `_hole_size`, `_annular_width`, `_hole_to_hole`, `_copper_clearance`, `_edge_clearance` (copper and silkscreen against the board's edges), `_connectivity`, `_disallow` (keepouts), `_courtyard_clearance`, `_solder_mask` (mask bridges, and silkscreen against the whole mask), `_silk_clearance` (silkscreen against silkscreen and the mask's openings), `_zone_connections` (starved thermal reliefs), `_misc` (`testOutline`: the board's outline), `_sliver_checker` (copper slivers, each layer's copper made by `forEachGeometryItem`'s order, `EDA_SHAPE::TransformShapeToPolygon`, `PCB_TRACK::TransformShapeToPolygon` and `PCB_TEXT::TransformShapeToPolygon`); `pcbnew/pcbexpr_functions.cpp` (`intersectsKeepout`: what a keepout area keeps out); `drc_cache_generator` and `drc_rtree` (the copper items' R-tree, and the silkscreen's and its targets', `QueryCollidingPairs`), `drc_item`), `pcbnew/board.cpp` (`UpdateBoardOutline`: the outline the silkscreen checks go by; `FillItemMap`: the items KiCad's report names), `pcbnew/pad.cpp`, `pcbnew/pcb_track.cpp`, `pcbnew/pcb_shape.cpp`, `pcbnew/pcb_text.cpp`, `pcbnew/zone.cpp` and `common/eda_shape.cpp` (items' shapes on the silkscreen and mask layers, their boxes, `TransformShapeToPolygon`, `TransformTextToPolySet`), `common/rc_item.cpp` and the items' `GetItemDescription`s (the items as KiCad's report describes them), `pcbnew/footprint.cpp` (net tie pad groups), `pcbnew/convert_shape_list_to_polygon.cpp` (`TestBoardOutlinesGraphicItems`, `BuildBoardPolygonOutlines`: the board's outline of its and its footprints' drawings), `pcbnew/board.cpp` and `pcbnew/footprint.cpp` (`Visit`: the order the board's drawings are collected in), `pcbnew/connectivity` (`connectivity_algo`, `connectivity_items`, `connectivity_data`: what touches what, its clusters, the nets propagated through them, dangling ends, a zone's isolated islands and those that touch one item only) and `pcbnew/ratsnest/ratsnest_data.cpp` (each net's missing connections), `pcbnew/board_design_settings.cpp` (the rules' defaults and severities) and `common/eda_units.cpp` (values as its messages give them); for footprints' courtyards (`Outlines.swift`, `Courtyards.swift`) `pcbnew/convert_shape_list_to_polygon.cpp` (`ConvertOutlineToPolygon`: drawings chained into outlines with holes), `pcbnew/footprint.cpp` (`BuildCourtyardCaches`) and `libs/kimath`'s `bezier_curves` (a curve's points); for texts in the KiCad font (`StrokeFont.swift`, `Texts.swift`) `common/font` (`stroke_font`, `glyph`, `font`: the stroke font, its glyphs placed, lines, markup and boxes), `include/font/font_metrics.h`, `common/markup_parser.cpp` (overbars, subscripts, superscripts, links), `common/callback_gal.cpp` (a glyph's segments), `common/eda_text.cpp` (`GetEffectiveTextShape`, `GetTextBox`, `GetEffectiveTextPenWidth`), `common/gr_text.cpp` (pen widths), `pcbnew/pcb_text.cpp` and `pcbnew/pcb_field.cpp` (`GetShownText`, `GetDrawRotation`, `GetBoundingBox`, `GetEffectiveShape`), `pcbnew/footprint.cpp` (`ResolveTextVar`), `common/common.cpp` (`ExpandTextVars`, `ResolveTextVars`), `common/string_utils.cpp` (`UnescapeString`) and `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp` (a text as KiCad reads it); for its via placer (`ViaPlacer.swift`) `pcbnew/tools/drawing_tool.cpp` (`VIA_PLACER`: where KiCad's Add Vias puts a via, its net, the design rules it keeps); for texts and footprints placed on their own (`BoardPlacing.swift`) `pcbnew/tools/drawing_tool.cpp` (`PlaceText`: a new text's style), `pcbnew/board_design_settings.cpp` (the text defaults of each class of layer, `GetLayerClass`), `include/gr_text.h` (`InferBold`), `pcbnew/tools/board_editor_control.cpp` (`PlaceFootprint`) and `pcbnew/load_select_footprint.cpp` (`loadFootprint`), with texts as `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp` writes them; for its box selection (`BoxSelection.swift`) `pcbnew/tools/pcb_selection_tool.cpp` (`SelectMultiple`: what a box drawn left to right or right to left takes), the items' `HitTest`s in `pcbnew/pcb_track.cpp`, `pcbnew/footprint.cpp` (with `GetBoundingBox`), `pcbnew/pad.cpp`, `pcbnew/zone.cpp` and `common/eda_shape.cpp` (with `getBoundingBox` and `computeArcBBox`), and `libs/kimath`'s `box2.h` and `trigo` (`SegmentIntersectsSegment`); for its zone filler (`ZoneFiller.swift`, `ZoneFillerCopper.swift`, `PolySetFill.swift`) `pcbnew/zone_filler.cpp` (`ZONE_FILLER::Fill`: copper and non-copper fills, thermal reliefs and spokes, clearances, keepouts, higher-priority zones, minimum width pruning, hatching, island removal, the iterative refill; its `VERTEX_CONNECTOR`), `pcbnew/zone.cpp` (`BuildSmoothedPoly`, `GetInteractingZones`, `HigherPriority`, `TransformShapeToPolygon`), `pcbnew/zone_settings.cpp` and `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp` (a zone's settings as read), `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp` (its fill as written), `pcbnew/drc/drc_engine.cpp` (`EvalRules` and `EvalZoneConnection` for the filler's constraints), `pcbnew/connectivity/connectivity_algo.cpp` (`FillIsolatedIslandsMap`), `pcbnew/board.cpp` (`GetBoardPolygonOutlines`, `ComputeBoundingBox`), `pcbnew/pad.cpp`, `pcbnew/pcb_track.cpp` and `pcbnew/pcb_text.cpp` (items' polygons, boxes and overrides), and `libs/kimath`'s `shape_poly_set` (`Deflate`, `Area`, `Contains`, `Unfracture`, `InflateWithLinkedHoles`, `Chamfer`, `Fillet`), `corner_operations`, `vertex_set` and `convex_hull`; for its teardrops (`Teardrops.swift`) `pcbnew/teardrop` (`teardrop.cpp`, `teardrop_utils.cpp`, `teardrop_parameters.cpp`, `teardrop.h` and `teardrop_parameters.h`: `TEARDROP_MANAGER` and its settings), `pcbnew/dialogs/dialog_global_edit_teardrops.cpp` (the settings set as its Set Teardrops dialog sets them), `pcbnew/board_design_settings.cpp` (the board's teardrop settings in its project), `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp` and `pcb_io_kicad_sexpr.cpp` (pads' and vias' teardrop settings and teardrop zones as read and written, and the order zones are written in), `pcbnew/pad.cpp` and `pcbnew/pcb_track.cpp` (hit tests, lengths), `pcbnew/drc/drc_rtree.h` (`CheckColliding`), `common/kiid.cpp` (`KIID::Combine`) and `libs/kimath`'s `convex_hull`, `trigo` (`TestSegmentHit`), `shape_poly_set` (`Collide`) and `bezier_curves`; for the board's setup (`BoardStackup.swift`, `BoardSetup.swift`, `BoardStackupEditing.swift`) `pcbnew/board_stackup_manager/board_stackup.cpp` (`BOARD_STACKUP_ITEM`'s defaults, `BuildDefaultStackupList`, `SynchronizeWithBoard`, `BuildBoardThicknessFromStackup`, `FormatBoardStackup`), `panel_board_stackup.cpp` (`buildLayerStackPanel`, `synchronizeWithBoard`, `showOnlyActiveLayers`, `onCopperLayersSelCount`, `setDefaultLayerWidths`, `computeBoardThickness`, `transferDataFromUIToStackup`, `TransferDataFromWindow`: the Physical Stackup page bringing the stackup to a new copper layer count) and `stackup_predefined_prms.cpp` (its colours and finishes), its rows edited (`lazyBuildRowUI`, `onAddDielectricLayer`, `onRemoveDielectricLayer`, `onMaterialChange`) with `dielectric_material.cpp` (KiCad's materials) and `panel_board_finish.cpp` (the Board Finish page), with the stackup as `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp` reads it (`parseBoardStackup`, `parseSetup`'s default stackup), `pcbnew/dialogs/panel_setup_layers.cpp` (`TransferDataFromWindow`, `transferDataFromWindow`, `getRemovedLayersWithItems`: a copper layer count changed), `pcbnew/board.cpp` (`RemoveAllItemsOnLayer`, `HasItemsOnLayer`), `pcbnew/collectors.cpp` (`BoardLevelItems`), `pcbnew/zone.cpp` (`SetLayerSet`), `pcbnew/board_design_settings.cpp` (`SetEnabledLayers`; `track_widths`, `via_dimensions`, `GetCurrentTrackWidth`, `GetCurrentViaSize`, `GetCurrentViaDrill`: the pre-defined sizes), `pcbnew/dialogs/panel_setup_tracks_and_vias.cpp` (the Pre-defined Sizes page's lists, `Validate`) with `pcbnew/pcb_track.cpp` (`ValidateViaParameters`), `pcbnew/router/router_tool.cpp` (its track width menu) and `pns_kicad_iface.cpp` (`ImportSizes`: the size chosen, routed), the layer table, a zone's layers and the stackup as `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp` writes them (`formatBoardLayers`, `formatLayers`, `formatSetup`), and `common/eda_units.cpp` and `common/string_utils.cpp` (`FormatInternalUnits`, `FormatDouble2Str`, `UIDouble2Str`: numbers as written and as the dialog shows them); for the design rules of a board's rules file and its implicit ones, which the design rules check, the zone filler and the router go by (`DesignRules.swift`, `DesignRulesCheck.swift`, `RuleExpressions.swift`, `RuleItems.swift`, `RuleFunctions.swift`, `RuleEngine.swift`, `DRCRules.swift`, `RouterRules.swift`) `pcbnew/drc/drc_rule_parser.cpp` and `common/drc_rules.keywords` (the rules file, and its errors as its reporter gives them), `pcbnew/dialogs/panel_setup_rules.cpp` (`OnCompile`, `checkPlausibility`: a rules file checked as Board Setup's Custom Rules page checks it), `common/dsnlexer.cpp` (how it is cut into tokens), `pcbnew/drc/drc_rule.cpp` and `drc_rule_condition.cpp` (rules, constraints, conditions), `libs/core/include/core/minoptmax.h`, `common/libeval_compiler/libeval_compiler.cpp` and `grammar.lemon` (the conditions' language: its tokens, grammar, code and stack machine), `pcbnew/pcbexpr_evaluator.cpp` (its variables, properties and units) and `pcbnew/pcbexpr_functions.cpp` (its functions, with the board's caches of an item's collisions with areas), `common/properties/property_mgr.cpp` and the properties the board items' classes register (`common/eda_item.cpp`, `eda_shape.cpp`, `eda_text.cpp`, `pcbnew/board_item.cpp`, `board_connected_item.cpp`, `pcb_track.cpp`, `pad.cpp`, `footprint.cpp`, `zone.cpp`, `pcb_shape.cpp`, `pcb_field.cpp`), `pcbnew/footprint_courtyard_index.cpp`, `pcbnew/drc/drc_engine.cpp` (`InitEngine`, `loadImplicitRules`, `compileRules`, `EvalRules`, `EvalZoneConnection`, `ProcessAssertions`, `QueryWorstConstraint`), `pcbnew/drc/drc_test_provider_misc.cpp` (`testAssertions`), `drc_test_provider_disallow.cpp` (the user's disallows), `pcbnew/board_design_settings.cpp` (`GetBiggestClearanceValue`), `common/eda_units.cpp` (values with units), `common/string_utils.cpp` (`WildCompareString`), `include/layer_ids.h`, `common/lset.cpp` and `common/layer_id.cpp` (layers by name), `pcbnew/router/pns_kicad_iface.cpp` (`PNS_PCBNEW_RULE_RESOLVER::QueryConstraint`, `Clearance` and its caches, the dummy items it asks about, `ImportSizes`) and `pcbnew/zone_filler.cpp` (the filler's constraints, a footprint's courtyard knocked out by a physical clearance); for zones' outlines edited after they are drawn (`BoardZoneEditing.swift`) `pcbnew/tools/pcb_point_editor.cpp` (`OnSelectionChange`'s drag, `snapCorner`, `addCorner`, `removeCorner`, `CanRemoveCorner`, `ZONE_POINT_EDIT_BEHAVIOR`), `common/tool/point_editor_behavior.cpp` (`POLYGON_POINT_EDIT_BEHAVIOR`), `common/tool/edit_constraints.cpp` (`EC_CONVERGING`, `EC_LINE`), `common/tool/edit_points.cpp` (its contours) and `libs/kimath/src/geometry/shape_poly_set.cpp` and `shape_line_chain.cpp` (`InsertVertex`, `RemoveVertex`, `RemoveContour`, `RemoveNullSegments`, `Remove`, `SetClosed`), and `pcbnew/zone.cpp` (`Move`, `UnFill`); for zones', footprints' and pads' properties (`BoardProperties.swift`, `BoardFootprintProperties.swift`, `BoardPadProperties.swift`) `pcbnew/edit_zone_helpers.cpp` (`Edit_Zone_Params`), `pcbnew/dialogs/panel_zone_properties.cpp` (`AcceptOptions`), `dialog_copper_zones.cpp` and `dialog_rule_area_properties.cpp` (`TransferDataFromWindow`), `pcbnew/zone_settings.cpp` (`operator<<`, `ExportSetting`), `pcbnew/board.cpp` (`MakeUniqueZoneName`), `pcbnew/dialogs/dialog_footprint_properties.cpp` (`Validate`, `OnAddField`, `TransferDataFromWindow`) with `pcbnew/pcb_fields_grid_table.cpp`, `pcbnew/footprint.cpp` (`Rotate`, `Flip`), `pcbnew/pcb_text.cpp` (`KeepUpright`, `Flip`), `common/gr_text.cpp` (`ClampTextPenSize`), `pcbnew/dialogs/dialog_pad_properties.cpp` (`initValues`, `onPadShapeSelection`, `transferDataToPad`, `TransferDataFromWindow`), `pcbnew/pad.cpp` (`Flip`, `SetAttribute`, `CanHaveNumber`) and `pcbnew/pad_utils.cpp` (`GetDefaultIpcRoundingRatio`), all written as `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp` writes them (`format` of a zone, a footprint's fields and attributes, a pad; `formatLayers`) and `common/eda_text.cpp` (`EDA_TEXT::Format`); for items locked (`BoardLocking.swift`) `pcbnew/tools/board_editor_control.cpp` (`modifyLockSelected`), `pcbnew/board_item.cpp` and `pad.cpp` (`IsLocked`) and `pcbnew/tools/pcb_selection_tool.cpp` (`FilterCollectorForLockedItems`, `selectPoint` on a drag); for its net inspector and net highlighting (`NetInspector.swift`, `NetHighlight.swift`) `pcbnew/widgets/pcb_net_inspector_panel.cpp` and `pcb_net_inspector_panel_data_model.h` (the panel's columns, nets, filter, groups, values and sorting), `pcbnew/length_delay_calculation/length_delay_calculation.cpp` and `length_delay_calculation_item.h` (`CalculateLengthDetails`: `optimiseVias`, `mergeLines`, `optimiseTracesInPads`, `StackupHeight`), `pcbnew/board.cpp` (`GetTrackLength`), `pcbnew/connectivity/connectivity_data.cpp` (`GetConnectedPads`, `GetConnectedItems`), `common/string_utils.cpp` (`ValueStringCompare`, `SplitString`, `ApplyModifier`), `common/eda_units.cpp`, `common/eda_pattern_match.cpp` (`EDA_COMBINED_MATCHER`), `pcbnew/tools/board_inspection_tool.cpp` (`highlightNet`, `HighlightNet`, `ClearHighlight`), `pcbnew/collectors.cpp` and `collectors.h` (`GENERAL_COLLECTOR`, `GENERAL_COLLECTORS_GUIDE`), `pcbnew/pcb_base_frame.cpp` (`GetCollectorsGuide`), `pcbnew/tools/pcb_selection_tool.cpp` (`itemPassesFilter`), `pcbnew/zone.cpp` (`HitTestForCorner`, `HitTestForEdge`, `HitTestFilledArea`) and `pcbnew/pcb_painter.cpp` (`PCB_RENDER_SETTINGS::GetColor`: highlighted nets and the high contrast mode); for graphics and dimensions drawn and edited, and the measure tool (`BoardGraphics.swift`, `Dimensions.swift`, `Measure.swift`, `BoardDrawing.swift`, and `BoardPlacing.swift`'s moves, turns and removals of drawings) `pcbnew/tools/drawing_tool.cpp` (`DrawLine`, `DrawRectangle`, `DrawCircle`, `DrawArc`, `DrawZone` drawing a polygon, `DrawDimension`, `drawShape`, `drawArc`, `constrainDimension`), `pcbnew/tools/zone_create_helper.cpp` (`OnComplete`, `commitZone`: the polygon made a graphic), `include/preview_items/two_point_geom_manager.h` and `multistep_geom_manager.h`, `common/preview_items/arc_geom_manager.cpp`, `polygon_geom_manager.cpp`, `ruler_item.cpp` and `preview_utils.cpp`, `pcbnew/tools/pcb_viewer_tools.cpp` (`MeasureTool`), `common/eda_shape.cpp` (`SetArcGeometry`, `GetArcMid`, `CalcArcAngles`, `getCenter`, `getPosition`, `computeArcBBox`, `move`, `rotate`), `pcbnew/pcb_shape.cpp` (`Normalize`), `pcbnew/tools/pcb_point_editor.cpp` (the point editor's drag, `RECTANGLE_POINT_EDIT_BEHAVIOR`, `snapCorner`, `addCorner`, `removeCorner`), `common/tool/point_editor_behavior.cpp` (the segment's, circle's, arc's and polygon's edit behaviours), `include/tool/edit_points.h` (`EDIT_LINE`), `common/tool/edit_constraints.cpp` (`EC_PERPLINE`), `common/tool/grid_helper.cpp` (`Align`), `pcbnew/tools/edit_tool.cpp` (`Rotate`'s centre), `pcbnew/pcb_dimension.cpp` (`PCB_DIMENSION_BASE` and its kinds: `updateGeometry`, `updateText`, `GetValueText`, `drawAnArrow`, `segPolyIntersection`, `segCircleIntersection`, `CollectKnockedOutSegments`, `Move`, `Rotate`), `pcbnew/board_design_settings.cpp` (`GetLineThickness`, the dimension defaults), `common/eda_units.cpp`, `libs/kimath`'s `geometry_utils.h` (`GetVectorSnapped45`, `GetVectorSnapped90`), `circle.cpp`, `box2.h` and `vector2d.h` (a vector divided, rounded), with graphics and dimensions as `pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp` writes them and its parser reads them; for copy, cut, paste, duplicate, Create Array and align and distribute (`BoardItems.swift`, `BoardClipboard.swift`, `BoardClipboardEditing.swift`, `BoardArray.swift`, `BoardAlign.swift`) `pcbnew/kicad_clipboard.cpp` (`CLIPBOARD_IO`: the clipboard's text), `pcbnew/tools/edit_tool.cpp` (`copyToClipboard`, `cutToClipboard`, `Duplicate`), `pcbnew/tools/pcb_control.cpp` (`Paste`, `pruneItemLayers`, `placeBoardItems`), `pcbnew/tools/pcb_grid_helper.cpp` (`BestDragOrigin`: the point a copy is picked up by), `pcbnew/tools/board_reannotate_tool.cpp` (`ReannotateDuplicates`) with `common/refdes_utils.cpp` and `common/string_utils.cpp` (`StrNumCmp`), `pcbnew/board.cpp` (`MapNets`, `GetUniqueZoneName`), `pcbnew/board_item.cpp`, `footprint.cpp` and `pcb_group.cpp` (`Duplicate`, `DeepDuplicate`), `pcbnew/board_commit.cpp` (`Push`: the nets propagated), `include/layer_range.h` (a pasted via's layers), `pcbnew/tools/array_tool.cpp` and `common/array_options.cpp` (`ARRAY_TOOL`, `TransformItem`, the grid's and the circle's places), `pcbnew/dialogs/dialog_create_array.cpp`, `pcbnew/tools/align_distribute_tool.cpp` and `libs/kimath/src/geometry/distribute.cpp`, the items' `Move`, `Rotate`, `SetPosition` and `GetPosition` (`pcbnew/footprint.cpp` with `cmp_drawings`, `pcb_track.cpp`, `zone.cpp`, `pcb_text.cpp` with `KeepUpright`, `pcb_group.cpp`, `pcb_generator.cpp`, `common/eda_shape.cpp`) and `libs/kimath`'s `roundrect`; and the stroke font's glyphs (`StrokeFontData.swift`, generated by `tools/kicad-reference/newstroke.py`) from `common/newstroke_font.cpp`, which has notices of its own (below) |
| `Sources/KiCadKit/LocalSettings.swift` (a project's local settings, the board's appearance in them, and KiCad's default colour theme) | `common/project/project_local_settings.cpp`, `common/settings/json_settings.cpp`, `thirdparty/nlohmann_json` (its serializer), `common/settings/layer_settings_utils.cpp`, `include/layer_ids.h`, `common/lset.cpp`, `include/base_set.h`, `common/settings/builtin_color_themes.h`, `common/settings/color_settings.cpp`, `pcbnew/widgets/appearance_controls.cpp` (its layers, objects, presets and how a click on them changes the appearance) |
| `Sources/JSpice/PCBAppearance.swift` (what the PCB view shows and lets the pointer pick) | `pcbnew/tools/pcb_selection_tool.cpp` (`Selectable`), `pcbnew/pcb_painter.cpp`, `pcbnew/widgets/appearance_controls.cpp` |
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

## wxWidgets

`WildMatch.matches` in `Sources/KiCadRouter/DesignRules.swift` (how KiCad's rules match a name against a wildcard)
follows `wxString::Matches` of wxWidgets 3.2 (`src/common/string.cpp`), which KiCad's rules call: Copyright the
wxWidgets team (https://www.wxwidgets.org), under the wxWindows Library Licence, Version 3.1 (the GNU Library General
Public License, version 2 or later, with an exception for binaries), which allows its use in GPL software.

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
