#!/usr/bin/env python3
"""Reads the call graph in a macOS `sample` report and prints where the time goes: each function's samples with all it
calls (inclusive), and for the runtime's helpers (copies, reference counts, uniqueness checks) which functions call
them, so a profile's anonymous memmove is traced to the copy that costs it.

    profile-callers.py build/profile-maker.txt [rows]
"""
import re
import sys
from collections import Counter, defaultdict

HELPERS = ("memmove", "memcpy", "memset", "isUniquelyReferenced", "swift_retain", "swift_release", "swift_bridgeObject",
           "malloc", "free", "swift_allocObject", "swift_beginAccess", "_checkSubscript")


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
    stack = []
    inclusive = Counter()
    callers = defaultdict(Counter)
    for line in lines[start + 1:]:
        if line.startswith("Total number in stack") or line.startswith("Sort by top of stack"):
            break
        match = frame.match(line)
        if not match:
            continue
        depth, count, symbol = len(match.group(1)), int(match.group(2)), match.group(3)
        while stack and stack[-1][0] >= depth:
            stack.pop()
        caller = stack[-1][1] if stack else "(root)"
        # a function that calls itself counts once
        if all(name != symbol for _, name in stack):
            inclusive[symbol] += count
        callers[symbol][caller] += count
        stack.append((depth, symbol))
    print("Inclusive samples (each function with all it calls):")
    for symbol, count in inclusive.most_common(rows):
        print(f"  {count:7d}  {symbol}")
    print("Runtime helpers, by caller:")
    helpers = [(symbol, sum(by.values())) for symbol, by in callers.items() if any(h in symbol for h in HELPERS)]
    for symbol, total in sorted(helpers, key=lambda item: -item[1])[:8]:
        print(f"  {total:7d}  {symbol}")
        for caller, count in callers[symbol].most_common(6):
            print(f"  {count:13d}  from {caller}")


if __name__ == "__main__":
    main()
