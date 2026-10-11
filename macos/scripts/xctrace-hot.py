#!/usr/bin/env python3
"""Reads Instruments' Time Profiler table (`xctrace export` of a run's time-profile table) and finds where, within one
function, the samples taken in it fall: each instruction's samples, the hottest first, with the address it has in the
binary. Time Profiler samples the instruction itself (the program counter), where `sample`'s report can put a
function's own samples at the return address of the last call it made. Prints the functions most sampled as well, and
writes an lldb command file that disassembles a few instructions before and after each hot one.

    xctrace-hot.py build/pico-time.xml CortexM0.runStretch [rows] [lldb-commands-file]
"""
import sys
import xml.etree.ElementTree as ElementTree
from collections import Counter


def main():
    path, wanted = sys.argv[1], sys.argv[2]
    rows = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    commands = sys.argv[4] if len(sys.argv) > 4 else None
    try:
        root = ElementTree.parse(path).getroot()
    except (ElementTree.ParseError, OSError) as error:
        print(f"{path}: {error}")
        return
    # (an element written once with an id, and after that as a ref to it)
    elements = {element.get("id"): element for element in root.iter() if element.get("id") is not None}

    def resolved(element):
        while element is not None and element.get("ref") is not None:
            element = elements.get(element.get("ref"))
        return element

    leaves = Counter()
    hot = Counter()
    names = {}
    samples = 0
    for row in root.iter("row"):
        # (the backtrace may sit in the row itself or deeper, as a tagged one, and be a ref to one written before)
        backtrace = next((resolved(element) for element in row.iter() if element.tag.endswith("backtrace")), None)
        if backtrace is None:
            continue
        frames = [resolved(frame) for frame in backtrace.iter("frame")]
        frames = [frame for frame in frames if frame is not None]
        if not frames:
            continue
        samples += 1
        leaf = resolved(frames[0])
        if leaf is None:
            continue
        name = leaf.get("name", "?")
        leaves[name] += 1
        if wanted not in name:
            continue
        address = int(leaf.get("addr", "0"), 16)
        binary = resolved(leaf.find("binary"))
        load = int(binary.get("load-addr", "0"), 16) if binary is not None else 0
        # (the binary's own address, its text at 0x100000000; the instruction's, the address given being one past its
        # start; a function inlined in another names its own instructions)
        static = (0x100000000 + address - load if load else address) & ~3
        hot[static] += 1
        names.setdefault(static, Counter())[name] += 1
    if samples == 0:
        # (for what the table looks like, to read it next time)
        with open(path, errors="replace") as file:
            print(file.read(3000))
        rows_seen = sum(1 for _ in root.iter("row"))
        print(f"{rows_seen} rows, tags: {sorted({element.tag for element in root.iter()})[:40]}")
    print(f"{samples} samples; the functions they fell in, most first:")
    for name, count in leaves.most_common(16):
        print(f"  {count:6d}  {name[:110]}")
    if not hot:
        print(f"no samples in {wanted}")
        return
    print(f"{wanted}: {sum(hot.values())} samples, by instruction:")
    lldb = []
    for address, count in hot.most_common(rows):
        print(f"  {count:6d}  [0x{address:x}]  {names[address].most_common(1)[0][0][:60]}")
        lldb.append(f"disassemble --start-address 0x{max(address - 24, 0):x} --count 10")
    if commands:
        with open(commands, "w") as file:
            file.write("\n".join(lldb) + "\n")


if __name__ == "__main__":
    main()
