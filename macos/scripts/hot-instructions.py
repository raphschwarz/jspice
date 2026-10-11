#!/usr/bin/env python3
"""Reads the call graph in a macOS `sample` report and finds where, within one function, its own samples fall: each
instruction's samples (those the function took itself, not in what it called), the hottest first, with the address it
has in the binary. Writes an lldb command file that disassembles a few instructions before and after each, so the cost
of an interpreter's loop can be seen instruction by instruction.

    hot-instructions.py build/profile-pico.txt executeInstruction [rows] [lldb-commands-file]
"""
import re
import sys
from collections import Counter

# a frame: its depth (where its count starts), its samples, its function and image, and where in the function
FRAME = re.compile(r"^([\s+!:|]*?)(\d+)\s+(.*?)\s+\(in ([^)]+)\)\s+\+\s+(\d+)\s+\[(0x[0-9a-f]+)\]")


def main():
    path, wanted = sys.argv[1], sys.argv[2]
    rows = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    commands = sys.argv[4] if len(sys.argv) > 4 else None
    with open(path, errors="replace") as file:
        lines = file.read().splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith("Call graph:")), None)
    if start is None:
        print(f"{path}: no call graph")
        return
    # where the program was loaded, to turn its addresses into the binary's own (its text at 0x100000000)
    load = None
    for line in lines:
        match = re.match(r"\s*(0x[0-9a-f]+)\s+-\s+0x[0-9a-f]+\s+\+?jspice-mcp", line)
        if match:
            load = int(match.group(1), 16)
            break
    frames = []  # (depth, count, symbol, image, offset, address)
    for line in lines[start + 1:]:
        if line.startswith("Total number in stack") or line.startswith("Sort by top of stack"):
            break
        match = FRAME.match(line)
        if match:
            frames.append((len(match.group(1)), int(match.group(2)), match.group(3), match.group(4), int(match.group(5)),
                           int(match.group(6), 16)))
    own = Counter()
    total = Counter()
    for k, (depth, count, symbol, image, offset, address) in enumerate(frames):
        if wanted not in symbol:
            continue
        # the frame's own samples: its count less those of the frames right below it (the first of them sets their
        # depth; the frames under those are theirs)
        below, child = 0, None
        for depth2, count2, *_ in frames[k + 1:]:
            if depth2 <= depth:
                break
            if child is None:
                child = depth2
            if depth2 == child:
                below += count2
        own[(symbol, offset, address)] += count - below
        total[symbol] += count - below
    if not own:
        print(f"{path}: no samples in {wanted}")
        return
    for symbol, count in total.most_common(3):
        print(f"{symbol}: {count} samples of its own")
    lldb = []
    for (symbol, offset, address), count in own.most_common(rows):
        static = 0x100000000 + (address - load) if load is not None else address
        print(f"  {count:6d}  {symbol} + {offset}  [0x{static:x}]")
        lldb.append(f"disassemble --start-address 0x{max(static - 24, 0):x} --count 10")
    if commands:
        with open(commands, "w") as file:
            file.write("\n".join(lldb) + "\n")


if __name__ == "__main__":
    main()
