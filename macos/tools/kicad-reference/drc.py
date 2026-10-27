#!/usr/bin/env python3
"""KiCad's design rules check of boards, for checking the port's (KiCadRouter's BoardDRC) against: kicad-cli's DRC of
each board as it is (its zones as filled when it was saved, not refilled), errors and warnings, written next to it
as BOARD.drc: kicad-cli's own report (JSON, https://schemas.kicad.org/drc.v1.json; named so that a folder's .json
files are its boards' scenes only), its date taken out, so that the same board gives the same file.

    drc.py BOARD.kicad_pcb...
"""

import json
import os
import subprocess
import sys
import tempfile


def main():
    for board in sys.argv[1:]:
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "drc.json")
            subprocess.run(["kicad-cli", "pcb", "drc", "--format", "json", "--units", "mm", "--severity-error",
                            "--severity-warning", "-o", out, board], check=True, stdout=subprocess.DEVNULL)
            with open(out) as f:
                report = json.load(f)
        report.pop("date", None)
        with open(os.path.splitext(board)[0] + ".drc", "w") as f:
            json.dump(report, f, indent=1, sort_keys=True)
            f.write("\n")


if __name__ == "__main__":
    main()
