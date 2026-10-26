#!/usr/bin/env python3
"""The changes build.sh makes to KiCad's sources before building them, so that KiCad's router answers the same way
each time it is run on the same board, and runs on items with no BOARD_ITEM behind them:

- Each router item gets a serial number when it is made (copies get their own), and obstacles are ordered by their
  items' serial numbers. KiCad orders them by address (OBSTACLE::operator< compares pointers), so where two obstacles
  are met at the same place, which goes first depends on where the memory allocator put them: one run to the next,
  one machine to the next. The Swift port orders them by the order they were made in, as these serial numbers do.
- The line placer asks a start pad's BOARD_ITEM its type, for a posture it then leaves unused; it is asked only if
  there is one.
- The router asks the BOARD_ITEM of a non-routable item at a route's start why it cannot be routed from (a hole with
  no plating, a rule area, a text); with none behind the item, it asks kicadReferenceNonRoutableReason, which
  router.cpp answers from the board's JSON as the BOARD_ITEM would.
- A branch of the router's world copies its parent's items into its own index, and a branch's changes are taken
  (GetUpdatedItems, Commit), in the order of their serial numbers. KiCad keeps a node's items in a hash set of
  pointers and takes them in its order, which comes from where the allocator put them; the order they go into a
  branch's R-trees in decides which of two obstacles a search that stops at the first finds first (as when a via is
  pushed clear of what it collides with, one obstacle at a time). The shove makes branches of branches, and a
  via's hole and the via are a pair such a search meets together. The Swift port takes them in the same order.
- The virtual vias a node makes where tracks of different widths meet (FixupVirtualVias, for the shove) are made
  for its joints in the order of their places (then nets and layers), not in the order of KiCad's hash map of
  joints, which comes from the hashes of their places; they go into the node's index in that order, and a search
  that stops at the first can meet one before another. The Swift port makes them in the same order.
- The items of a differential pair's coupled net that the pair could start or end on (FindDpPrimitivePair) are
  taken in the order they were made, not in the order of KiCad's set of pointers: of two the same distance away,
  the first taken is the one the pair goes from. The Swift port takes them in the same order.
- Where KiCad's router reads an arc as a segment (LINE_PLACER::simplifyNewLine casts a track at a joint it cleans
  up to a SEGMENT whatever it is, and reads an arc's memory as a segment's), which is undefined, it reports it to
  kicadReferenceUndefined, which stops the program with exit status 3, as router.cpp stops where it sees KiCad's
  undefined behaviour coming: such a board is no reference.
- The dot product DRAGGER::startDragArc takes to choose which way the stub it puts at an arc's free end goes
  overflows its ints for any arc of more than some 46 µm radius, which is undefined too; but its builds wrap the
  products and their sum round in 32 bits, the same every time (the stub then often goes back along the arc), and
  nearly every drag of an arc at a track's end comes to it, so it is made to wrap round explicitly (in unsigned
  ints, which C++ defines), not reported. The Swift port wraps them round the same way.

patch.py changes only what it has not changed already, so it can be run on sources it has changed before.

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

    patch(f"{router}/pns_router.cpp",
          "namespace PNS {",
          "/// Why a non-routable item with no BOARD_ITEM behind it cannot be routed from (kicad-reference)\n"
          "wxString kicadReferenceNonRoutableReason( const PNS::ITEM* aItem );\n"
          "\n"
          "namespace PNS {")

    patch(f"{router}/pns_router.cpp",
          "            BOARD_ITEM* parent = item->BoardItem();\n"
          "\n"
          "            switch( parent->Type() )",
          "            BOARD_ITEM* parent = item->BoardItem();\n"
          "\n"
          "            if( !parent )\n"
          "            {\n"
          "                wxString reason = kicadReferenceNonRoutableReason( item );\n"
          "\n"
          "                if( !reason.IsEmpty() )\n"
          "                    failureReason = reason;\n"
          "\n"
          "                continue;\n"
          "            }\n"
          "\n"
          "            switch( parent->Type() )")

    # a node's items, and its overrides, in the order they were made
    patch(f"{router}/pns_node.cpp",
          "NODE* NODE::Branch()\n{",
          "/// The items of a set in the order they were made (kicad-reference)\n"
          "template <class SET>\n"
          "static std::vector<ITEM*> bySerial( SET& aSet )\n"
          "{\n"
          "    std::vector<ITEM*> items( aSet.begin(), aSet.end() );\n"
          "    std::sort( items.begin(), items.end(),\n"
          "               []( const ITEM* a, const ITEM* b ) { return a->Serial() < b->Serial(); } );\n"
          "    return items;\n"
          "}\n"
          "\n"
          "\n"
          "NODE* NODE::Branch()\n{")

    patch(f"{router}/pns_node.cpp",
          "        for( ITEM* item : *m_index )\n"
          "            child->m_index->Add( item );",
          "        for( ITEM* item : bySerial( *m_index ) )\n"
          "            child->m_index->Add( item );")

    patch(f"{router}/pns_node.cpp",
          "    for( ITEM* item : m_override )\n"
          "        aRemoved.push_back( item );\n"
          "\n"
          "    for( ITEM* item : *m_index )\n"
          "        aAdded.push_back( item );",
          "    for( ITEM* item : bySerial( m_override ) )\n"
          "        aRemoved.push_back( item );\n"
          "\n"
          "    for( ITEM* item : bySerial( *m_index ) )\n"
          "        aAdded.push_back( item );")

    patch(f"{router}/pns_node.cpp",
          "    for( ITEM* item : aNode->m_override )\n"
          "        Remove( item );\n"
          "\n"
          "    for( ITEM* item : *aNode->m_index )\n"
          "    {",
          "    for( ITEM* item : bySerial( aNode->m_override ) )\n"
          "        Remove( item );\n"
          "\n"
          "    for( ITEM* item : bySerial( *aNode->m_index ) )\n"
          "    {")

    # the coupled net's items a differential pair could start from, in the order they were made
    patch(f"{router}/pns_diff_pair_placer.cpp",
          "    for( ITEM* item : coupledItems )\n"
          "    {\n"
          "        if( item->Kind() == aItem->Kind() )",
          "    std::vector<ITEM*> coupledBySerial( coupledItems.begin(), coupledItems.end() );\n"
          "    std::sort( coupledBySerial.begin(), coupledBySerial.end(),\n"
          "               []( const ITEM* a, const ITEM* b ) { return a->Serial() < b->Serial(); } );\n"
          "\n"
          "    for( ITEM* item : coupledBySerial )\n"
          "    {\n"
          "        if( item->Kind() == aItem->Kind() )")

    # an arc read as a segment, which is undefined: reported, so that router.cpp stops (exit status 3)
    patch(f"{router}/pns_line_placer.cpp",
          "namespace PNS {",
          "/// What KiCad's router does next is undefined: router.cpp stops (kicad-reference)\n"
          "void kicadReferenceUndefined( const char* aWhat );\n"
          "\n"
          "namespace PNS {")

    patch(f"{router}/pns_line_placer.cpp",
          "                    const SEG& testSeg = static_cast<const SEGMENT*>( neighbor )->Seg();",
          "                    if( neighbor->OfKind( ITEM::ARC_T ) )\n"
          "                        kicadReferenceUndefined( \"simplifyNewLine reads an arc as a segment\" );\n"
          "\n"
          "                    const SEG& testSeg = static_cast<const SEGMENT*>( neighbor )->Seg();")

    # the dot product of an arc drag's stub direction, which overflows its ints, wrapped round as KiCad's builds wrap it
    patch(f"{router}/pns_dragger.cpp",
          "            if( perp.x * toMid.x + perp.y * toMid.y > 0 )",
          "            if( (int) ( (unsigned) perp.x * (unsigned) toMid.x\n"
          "                        + (unsigned) perp.y * (unsigned) toMid.y ) > 0 )")

    # the world's joints, as virtual vias are made for them, in the order of their places (then nets and layers)
    patch(f"{router}/pns_node.cpp",
          "void NODE::FixupVirtualVias()\n{",
          "/// A node's joints by place, net and layer (kicad-reference)\n"
          "template <class MAP>\n"
          "static std::vector<const JOINT*> jointsByPlace( const MAP& aJoints )\n"
          "{\n"
          "    std::vector<const JOINT*> joints;\n"
          "\n"
          "    for( const auto& jointPair : aJoints )\n"
          "        joints.push_back( &jointPair.second );\n"
          "\n"
          "    std::sort( joints.begin(), joints.end(),\n"
          "               []( const JOINT* a, const JOINT* b )\n"
          "               {\n"
          "                   if( a->Pos().x != b->Pos().x )\n"
          "                       return a->Pos().x < b->Pos().x;\n"
          "\n"
          "                   if( a->Pos().y != b->Pos().y )\n"
          "                       return a->Pos().y < b->Pos().y;\n"
          "\n"
          "                   if( a->Net() != b->Net() )\n"
          "                       return std::less<NET_HANDLE>()( a->Net(), b->Net() );\n"
          "\n"
          "                   return a->Layers().Start() < b->Layers().Start();\n"
          "               } );\n"
          "\n"
          "    return joints;\n"
          "}\n"
          "\n"
          "\n"
          "void NODE::FixupVirtualVias()\n{")

    patch(f"{router}/pns_node.cpp",
          "    for( auto& jointPair : m_joints )\n"
          "    {\n"
          "        JOINT joint = jointPair.second;\n",
          "    for( const JOINT* placedJoint : jointsByPlace( m_joints ) )\n"
          "    {\n"
          "        JOINT joint = *placedJoint;\n")


if __name__ == "__main__":
    main()
