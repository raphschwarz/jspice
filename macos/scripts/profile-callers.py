#!/usr/bin/env python3
"""Reads the call graph in a macOS `sample` report and prints where the time goes: each function's samples with all it
calls (inclusive), and for the runtime's helpers (copies, reference counts, uniqueness checks, hashing) which functions
call them, so a profile's anonymous memmove is traced to the copy that costs it.

    profile-callers.py build/profile-maker.txt [rows]
"""
import re
import sys
from collections import Counter, defaultdict

HELPERS = ("memmove", "memcpy", "memset", "isUniquelyReferenced", "swift_retain", "swift_release", "swift_bridgeObject",
           "malloc", "free", "swift_allocObject", "swift_beginAccess", "_checkSubscript", "RefCounts", "dealloc", "arrayDestroy",
           "ContiguousArrayStorage", "swift_unowned", "swift_weak", "Hasher", "_NativeDictionary", "Set.contains",
           "Dictionary.subscript")


def main():
    path = sys.argv[1]
    rows = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    with open(path, errors="replace") as file:
        lines = file.read().splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith("Call graph:")), None)
    if start is None:
        print(f"{path}: no call graph")
        return
    # a frame: its depth (the column its count starts at), its samples, and the function
    frame = re.compile(r"^([\s+!:|]*?)(\d+)\s+(.*?)\s+\(in ([^)]+)\)")
    stack = []  # (depth, function, image)
    inclusive = Counter()
    callers = defaultdict(Counter)
    # for a helper, the nearest function of the program's own above it (a release's free is the program's)
    owners = defaultdict(Counter)
    program = None
    for line in lines[start + 1:]:
        if line.startswith("Total number in stack") or line.startswith("Sort by top of stack"):
            break
        match = frame.match(line)
        if not match:
            continue
        depth, count, symbol, image = len(match.group(1)), int(match.group(2)), match.group(3), match.group(4)
        if program is None and symbol.startswith("main"):
            program = image
        while stack and stack[-1][0] >= depth:
            stack.pop()
        caller = stack[-1][1] if stack else "(root)"
        # a function that calls itself counts once
        if all(name != symbol for _, name, _ in stack):
            inclusive[symbol] += count
        callers[symbol][caller] += count
        if any(h in symbol for h in HELPERS):
            owner = next((name for _, name, i in reversed(stack) if i == program and not any(h in name for h in HELPERS)), caller)
            owners[symbol][owner] += count
        stack.append((depth, symbol, image))
    print("Inclusive samples (each function with all it calls):")
    for symbol, count in inclusive.most_common(rows):
        print(f"  {count:7d}  {symbol}")
    print("Runtime helpers, by caller:")
    helpers = [(symbol, sum(by.values())) for symbol, by in callers.items() if any(h in symbol for h in HELPERS)]
    for symbol, total in sorted(helpers, key=lambda item: -item[1])[:10]:
        print(f"  {total:7d}  {symbol}")
        for caller, count in callers[symbol].most_common(4):
            print(f"  {count:13d}  from {caller}")
        for owner, count in owners[symbol].most_common(4):
            print(f"  {count:13d}  under {owner}")


if __name__ == "__main__":
    main()
