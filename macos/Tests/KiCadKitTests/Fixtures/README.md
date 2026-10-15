# KiCad fixtures

What KiCad itself wrote, for checking that JSpice reads and writes KiCad's files as KiCad does:

- `*.kicad_mod`, `flipped/*.kicad_mod`: footprints from KiCad 10.0.7's stock libraries (the KiCad Libraries, CC-BY-SA 4.0 with the KiCad libraries exception, https://www.kicad.org/libraries/license/).
- `zone.kicad_pcb`, `placed.kicad_pcb`: boards saved by KiCad 10.0.7's pcbnew (its Python module): footprints placed from the library, a track, a via and a filled zone.
- `flipped/flipped.kicad_pcb`: those footprints placed by pcbnew at 0°, 90° and 37° on the front and at 0°, 90° and -143° flipped onto the back; `flipped.json` lists each one's reference, footprint, angle and side.
