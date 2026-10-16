#!/usr/bin/env python3
"""The changes build.sh makes to KiCad's sources before building them, so that KiCad's router answers the same way
each time it is run on the same board, and runs on items with no BOARD_ITEM behind them:

- Each router item gets a serial number when it is made (copies get their own), and obstacles are ordered by their
  items' serial numbers. KiCad orders them by address (OBSTACLE::operator< compares pointers), so where two obstacles
  are met at the same place, which goes first depends on where the memory allocator put them: one run to the next,
  one machine to the next. The Swift port orders them by the order they were made in, as these serial numbers do.
- The line placer asks a start pad's BOARD_ITEM its type, for a posture it then leaves unused; it is asked only if
  there is one.

    patch.py KICAD_SOURCE_DIR
"""

import sys


def patch(path, old, new):
    with open(path) as f:
        text = f.read()
    if new in text:
        return
    if text.count(old) != 1:
        sys.exit(f"{path}: the text to change is not there once")
    with open(path, "w") as f:
        f.write(text.replace(old, new))


def main():
    src = sys.argv[1]
    router = f"{src}/pcbnew/router"

    patch(f"{router}/pns_item.h",
          "    bool            m_isCompoundShapePrimitive;\n};",
          "    bool            m_isCompoundShapePrimitive;\n"
          "\n"
          "public:\n"
          "    /// The order items are made in (kicad-reference)\n"
          "    uint64_t Serial() const { return m_serial; }\n"
          "\n"
          "private:\n"
          "    static inline uint64_t s_nextSerial = 0;\n"
          "    uint64_t        m_serial = s_nextSerial++;\n"
          "};")

    patch(f"{router}/pns_node.h",
          "        if( (uintptr_t)m_head < (uintptr_t)other.m_head )\n"
          "            return true;\n"
          "        else if ( m_head == other.m_head )\n"
          "            return (uintptr_t)m_item < (uintptr_t)other.m_item;\n"
          "        return false;",
          "        if( m_head->Serial() < other.m_head->Serial() )\n"
          "            return true;\n"
          "        else if ( m_head == other.m_head )\n"
          "            return m_item->Serial() < other.m_item->Serial();\n"
          "        return false;")

    patch(f"{router}/pns_line_placer.cpp",
          "static_cast<SOLID*>( aStartItem )->Parent()->Type() == PCB_PAD_T",
          "static_cast<SOLID*>( aStartItem )->Parent()\n"
          "             && static_cast<SOLID*>( aStartItem )->Parent()->Type() == PCB_PAD_T")


if __name__ == "__main__":
    main()
