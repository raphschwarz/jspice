# Adding a part

A kind of part is an `ElementKind`. The places that must know about it are listed here in order. "Compiler" means an
exhaustive switch fails to build until the new kind is listed; the tests named are in
`Tests/CircuitKitTests/PartCatalogTests.swift` unless stated otherwise. `PartFacts` (`PartCatalog.swift`) shows what
each place decided for a kind: `ElementKind.resistor.facts`.

## The engine (`Sources/CircuitKit`)

1. **`Element.swift`**: the `ElementKind` case; then `displayName`, `namePrefix`, `category`, `shortcut`, `terminalNames`
   and `params` (compiler). Also `shiftShortcut`, `models`, `Element.posts`, `defaultOffset` and `fixedLength`, which
   have `default:` arms, and the flags (`isModule`, `isAxisAligned`, `drivesOutput`) where they apply. Caught by
   `testEveryKindIsNamedAndHasTerminals` (one post per terminal), `testEveryParameterIsSane` (range holds the default,
   SI reads the unit back), `testEveryModelSetsParametersTheKindHas`, `testAFreshPartIsItsFirstModel`, and
   `testShortcutsAreUniqueAndKnownToClashOnlyWhereIntended`.
2. **A chip drawn as a box**: `chipPackage` in `LogicChips.swift`, or `audioChipPackage`, `audioParams` and
   `audioModels` in `AudioParts.swift`. A part simulated as other parts: `isExpandedPart` and `PartExpansion.build`
   (`testSimulationAndExportAgreeOnTheExpandedParts`).
3. **`Simulator.swift`**: `makeConstants`, the stamps (`fillBaseMatrix`, `stampNonlinear`, `fillRightHandSide`),
   `nonlinearIndices` and `drivenIndices`, the stepping, and `elementCurrents` for scopes. These still have `default:`
   arms, so nothing fails here: write a simulator test of the part's own behaviour.
4. **`Pacing.role(of:)`** (compiler), and its parameters in `timeScales` when it has a time of its own
   (`testPacingDecidesOnEveryKind`).
5. **`SchematicLayout.flow`** (compiler); a directed part also needs its entries in `inputs` and `outputs`
   (`testTheLayoutKnowsHowToPlaceEveryKind`, `testEveryPlaceableKindLaysOutAlone`).
6. **`Breadboard.mount`** (compiler); then `Breadboard.package` for a chip, `describe` for a two-lead part, `inline`
   and `transistor` for one with its legs in a row, or `offBoardTitle` for one wired from off the board
   (`testTheBreadboardDecidesOnEveryKind`, `testEveryRealPartOffTheBoardSaysWhatItIs`, and
   `testOnePartOfEveryKindGoesWhereItsFactsSay`, which lays out a part of every kind on the breadboard, stripboard and
   perfboard, verifies each and checks the KiCad export's unassigned footprints).
7. **`Stripboard.onPanel`**, for a control that goes in the box's lid. **`KiCadNetlist.footprint`** and
   **`BoardSVG.part`** are exhaustive over `Breadboard.Style`: only a new style needs them (compiler).
8. **`SpiceNetlist.exportForm`** (compiler), and the part's case in `Deck.add` when it is written
   (`testEveryKindIsExportedOrSaysWhyNot`: the deck leaves out exactly the `noEquivalent` kinds, and an exported
   part's deck reads back without warnings).

## The app (`Sources/JSpice`)

9. **`SymbolRenderer`**: `bodyLength`, `draw`, `segments` and `dotPath`, and the body in `drawTwoTerminal` for a
   two-terminal part (compiler, on macOS only: the Linux build leaves the app out).
10. **`SymbolIcons.image`** in `LibrarySidebar.swift`: the icon's frame and posts (compiler, on macOS).

## Then

11. The examples (`Examples.swift`), if one shows the part: the board tests (`BreadboardTests`, `StripboardTests`,
    `PerfboardTests`) and `SchematicLayoutTests` lay out and verify every example.
12. `docs/parts.md`, and `docs/shortcuts.md` if it has a key.

Run `PartCatalogTests` first: it names the kind and the piece that is missing.
