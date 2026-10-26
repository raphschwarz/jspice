// KiCad's own interactive router (pcbnew/router, KiCad 10.0.7) driven on a board given as JSON: its pads, tracks,
// vias and outline, and the routes to make on it (where each starts, where the pointer goes, where it is fixed).
// For each route it writes what KiCad's router does: the head and the tail after each step (a move, a via, a layer
// switch, a fix, an undo), whether the route was fixed, and the tracks and vias it put on the board (and, for a scene
// that asks, those it took off: a route that shoves replaces what it shoved). Each route walks round obstacles,
// shoves them or marks them, as it says. A route can be a drag instead (a track's segment or corner, or a via, as
// the router tool's drag tools drag them), with what the dragger dragged after each step. KiCadRouterTests runs the
// Swift port on the same boards and compares. build.sh builds this against KiCad's sources.
//
// The board's rules are KiCad's default board rules made simple: one clearance between copper of different nets,
// a hole clearance, a hole to hole clearance and an edge clearance, as PNS_PCBNEW_RULE_RESOLVER::Clearance combines
// them (items here have no BOARD_ITEM behind them, so what it asks of them is answered from the JSON).
//
// This program links KiCad's code: GNU General Public License version 3 or later, as KiCad.

#include <algorithm>
#include <cstdlib>
#include <deque>
#include <functional>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <stack>
#include <unordered_map>
#include <vector>

#include <geometry/shape_arc.h>
#include <geometry/shape_circle.h>
#include <geometry/shape_poly_set.h>
#include <geometry/shape_rect.h>
#include <geometry/shape_segment.h>
#include <geometry/shape_simple.h>
#include <nlohmann/json.hpp>
#include <pns_debug_decorator.h>
#include <pns_drag_algo.h>
#include <pns_hole.h>
#include <pns_line.h>
#include <pns_node.h>
#include <pns_router.h>
#include <pns_routing_settings.h>
#include <pns_segment.h>
#include <pns_solid.h>
#include <pns_via.h>

// (the line placer's fixed stages and the shove's springback stack, which undefinedUndo looks at)
#define private public
#include <pns_line_placer.h>
#include <pns_shove.h>
#undef private

using json = nlohmann::json;

static VECTOR2I pt( const json& j ) { return VECTOR2I( j[0].get<int>(), j[1].get<int>() ); }
static json pt( const VECTOR2I& p ) { return json::array( { p.x, p.y } ); }

static json chainPoints( const SHAPE_LINE_CHAIN& c )
{
    json a = json::array();

    for( int i = 0; i < c.PointCount(); i++ )
        a.push_back( pt( c.CPoint( i ) ) );

    return a;
}

static SHAPE* makeShape( const json& j )
{
    if( j.contains( "circle" ) )
        return new SHAPE_CIRCLE( pt( j["circle"] ), j["r"].get<int>() );

    if( j.contains( "rect" ) )
    {
        VECTOR2I p = pt( j["rect"] ), s = pt( j["size"] );
        return new SHAPE_RECT( p, s.x, s.y );
    }

    if( j.contains( "segment" ) )
        return new SHAPE_SEGMENT( pt( j["segment"][0] ), pt( j["segment"][1] ), j["w"].get<int>() );

    if( j.contains( "arc" ) )
        return new SHAPE_ARC( pt( j["arc"][0] ), pt( j["arc"][1] ), pt( j["arc"][2] ), j.value( "w", 0 ) );

    SHAPE_SIMPLE* s = new SHAPE_SIMPLE();

    for( const json& p : j["simple"] )
        s->Append( pt( p ) );

    return s;
}

/// The scene's nets: NET_HANDLEs are pointers to these (0 is the orphaned net, as KiCad's NETINFO_LIST::OrphanedItem)
static int g_nets[1024];

static PNS::NET_HANDLE netHandle( int aCode ) { return &g_nets[aCode]; }
static int netCode( PNS::NET_HANDLE aNet ) { return aNet ? int( static_cast<int*>( aNet ) - g_nets ) : -1; }

/// What the JSON says of an item that KiCad would read from its BOARD_ITEM
struct ITEM_INFO
{
    std::string        kind; // pad, track, via, edge, graphic, text, keepout
    bool               npth = false;
    bool               copper = true;      // BOARD_ITEM::IsOnCopperLayer
    bool               drilled = false;    // BOARD_ITEM::HasDrilledHole
    bool               npthSlot = false;
    std::optional<int> clearanceOverride;  // BOARD_CONNECTED_ITEM::GetClearanceOverrides
    std::vector<bool>  flashed;            // PAD::FlashLayer, PCB_VIA::FlashLayer, by router layer
    json               keepout;            // a keepout zone's rules
    std::string        footprint;          // the footprint a pad or keepout zone is part of

    /// BOARD_ITEM::IsConnected: a pad, track, via or drawing; not a text or a rule area
    bool connected() const { return kind != "text" && kind != "keepout"; }
};

class SCENE_RESOLVER : public PNS::RULE_RESOLVER
{
public:
    std::map<const PNS::ITEM*, ITEM_INFO> m_info;
    int m_clearance = 200000;
    int m_holeClearance = 250000;
    int m_holeToHole = 250000;
    int m_edgeClearance = 500000;
    int m_epsilon = 0;

    // A board's rules (scene "rules": "board"), as KiCad's DRC engine works them out with no rules of the user's
    // own: each net's net class clearance, a pad's or its footprint's own clearance first, the board's minimums
    bool               m_board = false;
    std::map<int, int> m_netClearance;

    const ITEM_INFO* info( const PNS::ITEM* aItem ) const
    {
        if( !aItem )
            return nullptr;

        const PNS::ITEM* key = aItem->OfKind( PNS::ITEM::HOLE_T ) && aItem->ParentPadVia() ? aItem->ParentPadVia() : aItem;
        auto it = m_info.find( key );
        return it == m_info.end() ? nullptr : &it->second;
    }

    bool isHole( const PNS::ITEM* aItem ) const { return aItem && aItem->OfKind( PNS::ITEM::HOLE_T ); }

    bool isEdge( const PNS::ITEM* aItem ) const
    {
        const ITEM_INFO* i = info( aItem );
        return i && i->kind == "edge" && !isHole( aItem );
    }

    bool isCopper( const PNS::ITEM* aItem ) const
    {
        const ITEM_INFO* i = info( aItem );

        if( !m_board )
            return !( i && i->kind == "pad" && i->npth );

        return !i || i->copper;
    }

    /// DRC_ENGINE::EvalRules's "non copper": not on a copper layer, or a keepout zone
    bool nonCopper( const PNS::ITEM* aItem ) const
    {
        const ITEM_INFO* i = info( aItem );
        return i && ( !i->copper || i->kind == "keepout" );
    }

    bool connected( const PNS::ITEM* aItem ) const
    {
        const ITEM_INFO* i = info( aItem );
        return !i || i->connected();
    }

    std::optional<int> override( const PNS::ITEM* aItem ) const
    {
        const ITEM_INFO* i = info( aItem );
        return i ? i->clearanceOverride : std::nullopt;
    }

    int netClearance( const PNS::ITEM* aItem ) const
    {
        auto it = m_netClearance.find( netCode( aItem->Net() ) );
        return it == m_netClearance.end() ? 0 : it->second;
    }

    /// The local overrides of either item, the larger, and no less than `aMinimum` (EvalRules's "local overrides
    /// take precedence over everything except board min clearance")
    std::optional<int> overrides( const PNS::ITEM* aA, const PNS::ITEM* aB, int aMinimum ) const
    {
        std::optional<int> a, b;

        if( aA && connected( aA ) && !( aB && nonCopper( aB ) ) )
            a = override( aA );

        if( aB && connected( aB ) && !( aA && nonCopper( aA ) ) )
            b = override( aB );

        if( !a && !b )
            return std::nullopt;

        int v = a.value_or( 0 );

        if( b && *b > v )
            v = *b;

        if( !v )
            return std::nullopt;

        return std::max( v, aMinimum );
    }

    /// QueryConstraint, for the constraint types the router asks of a board without rules of its own
    int boardConstraint( PNS::CONSTRAINT_TYPE aType, const PNS::ITEM* aA, const PNS::ITEM* aB ) const
    {
        switch( aType )
        {
        case PNS::CONSTRAINT_TYPE::CT_CLEARANCE:
        {
            if( std::optional<int> v = overrides( aA, aB, m_clearance ) )
                return *v;

            if( nonCopper( aA ) || ( aB && nonCopper( aB ) ) )
                return 0;

            int c = 0;

            if( connected( aA ) )
                c = netClearance( aA );

            if( aB && connected( aB ) )
                c = std::max( c, netClearance( aB ) );

            return std::max( c, m_clearance );
        }
        case PNS::CONSTRAINT_TYPE::CT_HOLE_CLEARANCE:
            if( std::optional<int> v = overrides( aA, aB, m_holeClearance ) )
                return *v;

            return m_holeClearance;
        case PNS::CONSTRAINT_TYPE::CT_HOLE_TO_HOLE: return m_holeToHole;
        case PNS::CONSTRAINT_TYPE::CT_EDGE_CLEARANCE: return m_edgeClearance;
        default: return 0;
        }
    }

    int Clearance( const PNS::ITEM* aA, const PNS::ITEM* aB, bool aUseClearanceEpsilon ) override
    {
        int  rv = 0;
        bool sameNet = aA && aB && aA->Net() && aA->Net() == aB->Net();
        bool freePad = aA && aB && ( aA->IsFreePad() || aB->IsFreePad() );

        auto query = [&]( PNS::CONSTRAINT_TYPE aType, int aSimple )
        {
            return m_board ? boardConstraint( aType, aA, aB ) : aSimple;
        };

        if( IsDrilledHole( aA ) && IsDrilledHole( aB ) )
            rv = std::max( rv, query( PNS::CONSTRAINT_TYPE::CT_HOLE_TO_HOLE, m_holeToHole ) );
        else if( isHole( aA ) || isHole( aB ) )
        {
            if( !sameNet )
                rv = std::max( rv, query( PNS::CONSTRAINT_TYPE::CT_HOLE_CLEARANCE, m_holeClearance ) );
        }

        if( isCopper( aA ) && ( !aB || isCopper( aB ) ) && !sameNet && !freePad )
            rv = std::max( rv, query( PNS::CONSTRAINT_TYPE::CT_CLEARANCE, m_clearance ) );

        if( isEdge( aA ) || IsNonPlatedSlot( aA ) || isEdge( aB ) || IsNonPlatedSlot( aB ) )
            rv = std::max( rv, query( PNS::CONSTRAINT_TYPE::CT_EDGE_CLEARANCE, m_edgeClearance ) );

        if( ( sameNet || freePad ) && rv == 0 )
            rv = -1;

        if( aUseClearanceEpsilon && rv > 0 )
            rv = std::max( 0, rv - m_epsilon );

        return rv;
    }

    PNS::NET_HANDLE DpCoupledNet( PNS::NET_HANDLE aNet ) override { return nullptr; }
    int DpNetPolarity( PNS::NET_HANDLE aNet ) override { return 0; }
    bool DpNetPair( const PNS::ITEM* aItem, PNS::NET_HANDLE& aNetP, PNS::NET_HANDLE& aNetN ) override { return false; }
    int NetCode( PNS::NET_HANDLE aNet ) override { return netCode( aNet ); }
    wxString NetName( PNS::NET_HANDLE aNet ) override { return wxString::Format( "Net-%d", netCode( aNet ) ); }
    bool IsInNetTie( const PNS::ITEM* aA ) override { return false; }
    bool IsNetTieExclusion( const PNS::ITEM*, const VECTOR2I&, const PNS::ITEM* ) override { return false; }

    bool IsDrilledHole( const PNS::ITEM* aItem ) override
    {
        const ITEM_INFO* i = info( aItem );

        if( m_board )
            return isHole( aItem ) && i && ( i->kind == "via" || i->drilled );

        return isHole( aItem ) && i && ( i->kind == "pad" || i->kind == "via" );
    }

    bool IsNonPlatedSlot( const PNS::ITEM* aItem ) override
    {
        const ITEM_INFO* i = info( aItem );
        return m_board && isHole( aItem ) && i && i->npthSlot;
    }

    /// Whether `aObstacle` is a keepout zone; if so, `aEnforce` whether it keeps `aItem` out. (KiCad asks it of the
    /// board item it makes for the router item's kind: a track for a segment or line, a via for a via or a hole,
    /// nothing for a pad.)
    bool IsKeepout( const PNS::ITEM* aObstacle, const PNS::ITEM* aItem, bool* aEnforce ) override
    {
        const ITEM_INFO* i = info( aObstacle );

        if( !i || i->kind != "keepout" )
            return false;

        const json& k = i->keepout;
        bool        enforce = false;

        if( aItem->OfKind( PNS::ITEM::SEGMENT_T | PNS::ITEM::LINE_T | PNS::ITEM::ARC_T ) )
            enforce = k.value( "tracks", false );
        else if( aItem->OfKind( PNS::ITEM::VIA_T | PNS::ITEM::HOLE_T ) )
            enforce = k.value( "vias", false );

        *aEnforce = enforce;
        return true;
    }

    bool QueryConstraint( PNS::CONSTRAINT_TYPE aType, const PNS::ITEM* aA, const PNS::ITEM* aB, int,
                          PNS::CONSTRAINT* aConstraint ) override
    {
        int v = 0;

        if( m_board )
        {
            switch( aType )
            {
            case PNS::CONSTRAINT_TYPE::CT_CLEARANCE:
            case PNS::CONSTRAINT_TYPE::CT_HOLE_CLEARANCE:
            case PNS::CONSTRAINT_TYPE::CT_HOLE_TO_HOLE:
            case PNS::CONSTRAINT_TYPE::CT_EDGE_CLEARANCE: v = boardConstraint( aType, aA, aB ); break;
            default: return false;
            }
        }
        else
        {
            switch( aType )
            {
            case PNS::CONSTRAINT_TYPE::CT_CLEARANCE: v = m_clearance; break;
            case PNS::CONSTRAINT_TYPE::CT_HOLE_CLEARANCE: v = m_holeClearance; break;
            case PNS::CONSTRAINT_TYPE::CT_HOLE_TO_HOLE: v = m_holeToHole; break;
            case PNS::CONSTRAINT_TYPE::CT_EDGE_CLEARANCE: v = m_edgeClearance; break;
            default: return false;
            }
        }

        aConstraint->m_Type = aType;
        aConstraint->m_Value.SetMin( v );
        aConstraint->m_Value.SetOpt( v );
        return true;
    }

    int ClearanceEpsilon() const override { return m_epsilon; }
};

/// KiCad's own debug trace (its PNS_DBG calls), written to standard error when KICAD_ROUTER_DEBUG is set
class TRACE_DECORATOR : public PNS::DEBUG_DECORATOR
{
public:
    int m_depth = 0;

    std::string indent() const { return std::string( 2 * m_depth, ' ' ); }

    static std::string chain( const SHAPE_LINE_CHAIN& c )
    {
        std::string s;

        for( int i = 0; i < c.PointCount(); i++ )
            s += " (" + std::to_string( c.CPoint( i ).x ) + "," + std::to_string( c.CPoint( i ).y ) + ")";

        return s;
    }

    static std::string shape( const SHAPE* aShape )
    {
        if( !aShape )
            return "";

        switch( aShape->Type() )
        {
        case SH_LINE_CHAIN: return chain( *static_cast<const SHAPE_LINE_CHAIN*>( aShape ) );
        case SH_SIMPLE: return chain( static_cast<const SHAPE_SIMPLE*>( aShape )->Vertices() );
        case SH_SEGMENT:
        {
            const SEG& s = static_cast<const SHAPE_SEGMENT*>( aShape )->GetSeg();
            return " seg" + chain( SHAPE_LINE_CHAIN( { s.A, s.B } ) );
        }
        case SH_CIRCLE:
        {
            auto c = static_cast<const SHAPE_CIRCLE*>( aShape );
            return " circle (" + std::to_string( c->GetCenter().x ) + "," + std::to_string( c->GetCenter().y ) + ") r "
                   + std::to_string( c->GetRadius() );
        }
        case SH_RECT:
        {
            BOX2I b = aShape->BBox();
            return " rect" + chain( SHAPE_LINE_CHAIN( { b.GetOrigin(), b.GetEnd() } ) );
        }
        default: return " ?";
        }
    }

    void Message( const wxString& msg, const SRC_LOCATION_INFO& ) override
    {
        std::cerr << indent() << msg.ToStdString() << "\n";
    }

    void BeginGroup( const wxString& name, int, const SRC_LOCATION_INFO& ) override
    {
        std::cerr << indent() << "[" << name.ToStdString() << "]\n";
        m_depth++;
    }

    void EndGroup( const SRC_LOCATION_INFO& ) override { m_depth = std::max( 0, m_depth - 1 ); }

    void AddPoint( const VECTOR2I& aP, const KIGFX::COLOR4D&, int, const wxString& aName, const SRC_LOCATION_INFO& ) override
    {
        std::cerr << indent() << aName.ToStdString() << ": point (" << aP.x << "," << aP.y << ")\n";
    }

    void AddItem( const PNS::ITEM* aItem, const KIGFX::COLOR4D&, int, const wxString& aName,
                  const SRC_LOCATION_INFO& ) override
    {
        std::cerr << indent() << aName.ToStdString() << ": " << aItem->KindStr() << shape( aItem->Shape( -1 ) ) << "\n";
    }

    void AddShape( const SHAPE* aShape, const KIGFX::COLOR4D&, int, const wxString& aName,
                   const SRC_LOCATION_INFO& ) override
    {
        std::cerr << indent() << aName.ToStdString() << ":" << shape( aShape ) << "\n";
    }
};

class SCENE_IFACE : public PNS::ROUTER_IFACE
{
public:
    json                         m_items;
    int                          m_layers = 2;
    SCENE_RESOLVER               m_resolver;
    std::vector<PNS::ITEM*>      m_byIndex;
    std::vector<json>            m_added;
    json                         m_triangles;     // the keepout zones' triangles, as SyncWorld made them
    int                          m_maxClearance = -1;
    PNS::NODE*                   m_world = nullptr;

    void SyncWorld( PNS::NODE* aWorld ) override
    {
        m_world = aWorld;
        m_byIndex.clear();
        m_resolver.m_info.clear();
        m_triangles = json::array();

        for( const json& j : m_items )
        {
            std::string kind = j["kind"];
            PNS::ITEM*  item = nullptr;
            ITEM_INFO   info{ kind, j.value( "npth", false ) };
            info.copper = j.value( "copper", kind != "edge" );
            info.drilled = j.value( "drilled", false );
            info.npthSlot = j.value( "npthSlot", false );

            if( j.contains( "clearanceOverride" ) )
                info.clearanceOverride = j["clearanceOverride"].get<int>();

            if( j.contains( "flashed" ) )
                info.flashed = j["flashed"].get<std::vector<bool>>();

            info.footprint = j.value( "footprint", "" );

            auto layersOf = [&]( PNS_LAYER_RANGE aDefault )
            {
                return j.contains( "layers" ) ? PNS_LAYER_RANGE( j["layers"][0].get<int>(), j["layers"][1].get<int>() )
                                              : aDefault;
            };

            if( kind == "pad" || kind == "edge" || kind == "graphic" || kind == "text" )
            {
                // syncPad, syncGraphicalItem, syncTextItem
                auto solid = std::make_unique<PNS::SOLID>();
                solid->SetLayers( kind == "edge" ? layersOf( PNS_LAYER_RANGE( 0, m_layers - 1 ) ) : layersOf( PNS_LAYER_RANGE( 0, 0 ) ) );

                if( kind == "edge" || kind == "text" || j.value( "npth", false ) )
                    solid->SetRoutable( false );

                // (a text has no net; anything else a net, the orphaned one if none of its own)
                solid->SetNet( kind == "text" ? nullptr : netHandle( j.value( "net", 0 ) ) );

                if( j.value( "freePad", false ) )
                    solid->SetIsFreePad();

                if( j.contains( "pos" ) )
                    solid->SetPos( pt( j["pos"] ) );

                if( j.contains( "offset" ) )
                    solid->SetOffset( pt( j["offset"] ) );

                if( j.contains( "hole" ) && !j["hole"].is_null() )
                {
                    solid->SetHole( new PNS::HOLE( makeShape( j["hole"] ) ) );
                    solid->Hole()->SetLayers( PNS_LAYER_RANGE( 0, m_layers - 1 ) );
                }

                solid->SetShape( makeShape( j["shape"] ) );

                if( j.value( "compound", false ) )
                    solid->SetIsCompoundShapePrimitive();

                item = solid.get();
                m_resolver.m_info[item] = info;
                aWorld->Add( std::move( solid ) );
            }
            else if( kind == "keepout" )
            {
                // syncZone: the rule area's outline cut into triangles, by KiCad's code, each a solid on each layer
                SHAPE_POLY_SET poly;

                for( const json& polygon : j["polygons"] )
                {
                    poly.NewOutline();

                    for( const json& p : polygon[0] )
                        poly.Append( pt( p ) );

                    for( size_t h = 1; h < polygon.size(); h++ )
                    {
                        poly.NewHole();

                        for( const json& p : polygon[h] )
                            poly.Append( pt( p ), -1, poly.HoleCount( poly.OutlineCount() - 1 ) - 1 );
                    }
                }

                poly.CacheTriangulation( false );
                info.keepout = j["keepout"];

                // (a zone KiCad cannot cut it leaves out, telling the user it is malformed)
                for( const json& layer : poly.IsTriangulationUpToDate() ? j["layers"] : json::array() )
                {
                    for( unsigned int polyId = 0; polyId < poly.TriangulatedPolyCount(); polyId++ )
                    {
                        const SHAPE_POLY_SET::TRIANGULATED_POLYGON* tri = poly.TriangulatedPolygon( polyId );

                        for( size_t i = 0; i < tri->GetTriangleCount(); i++ )
                        {
                            VECTOR2I a, b, c;
                            tri->GetTriangle( i, a, b, c );
                            SHAPE_SIMPLE* triShape = new SHAPE_SIMPLE;
                            triShape->Append( a );
                            triShape->Append( b );
                            triShape->Append( c );
                            auto solid = std::make_unique<PNS::SOLID>();
                            solid->SetLayer( layer.get<int>() );
                            solid->SetNet( nullptr );
                            solid->SetShape( triShape );
                            solid->SetIsCompoundShapePrimitive();
                            solid->SetRoutable( false );

                            if( !item )
                                item = solid.get();

                            m_resolver.m_info[solid.get()] = info;
                            m_triangles.push_back( { { "layer", layer }, { "triangle", chainPoints( triShape->Vertices() ) } } );
                            aWorld->Add( std::move( solid ) );
                        }
                    }
                }
            }
            else if( kind == "track" )
            {
                auto seg = std::make_unique<PNS::SEGMENT>( SEG( pt( j["a"] ), pt( j["b"] ) ), netHandle( j["net"] ) );
                seg->SetWidth( j["width"] );
                seg->SetLayer( j["layer"] );

                if( j.value( "locked", false ) )
                    seg->Mark( PNS::MK_LOCKED );

                item = seg.get();
                m_resolver.m_info[item] = info;
                aWorld->Add( std::move( seg ), true );
            }
            else if( kind == "via" )
            {
                PNS_LAYER_RANGE layers( j["layers"][0].get<int>(), j["layers"][1].get<int>() );
                auto via = std::make_unique<PNS::VIA>( pt( j["pos"] ), layers, 0, j["drill"].get<int>(),
                                                       netHandle( j["net"] ) );
                via->SetDiameter( 0, j["diameter"] );

                if( j.value( "locked", false ) )
                    via->Mark( PNS::MK_LOCKED );

                via->SetIsFree( j.value( "free", false ) );
                via->SetHole( PNS::HOLE::MakeCircularHole( pt( j["pos"] ), j["drill"].get<int>() / 2, layers ) );
                via->SetHoleLayers( layers );
                item = via.get();
                m_resolver.m_info[item] = info;
                aWorld->Add( std::move( via ) );
            }

            // (an arc track is left out: the Swift port has no arcs in its lines yet, and both leave them out)
            m_byIndex.push_back( item );
        }

        int worst = m_maxClearance >= 0 ? m_maxClearance
                                        : std::max( { m_resolver.m_clearance, m_resolver.m_holeClearance,
                                                      m_resolver.m_holeToHole, m_resolver.m_edgeClearance } );
        aWorld->SetRuleResolver( &m_resolver );
        aWorld->SetMaxClearance( worst + m_resolver.ClearanceEpsilon() );
    }

    /// A track or via as the scene gives it (null for anything else)
    static json itemJSON( const PNS::ITEM* aItem )
    {
        if( aItem->Kind() == PNS::ITEM::SEGMENT_T )
        {
            auto s = static_cast<const PNS::SEGMENT*>( aItem );
            return { { "kind", "track" }, { "net", netCode( s->Net() ) }, { "layer", s->Layer() },
                     { "a", pt( s->Seg().A ) }, { "b", pt( s->Seg().B ) }, { "width", s->Width() } };
        }
        else if( aItem->Kind() == PNS::ITEM::VIA_T )
        {
            auto v = static_cast<const PNS::VIA*>( aItem );
            return { { "kind", "via" }, { "net", netCode( v->Net() ) }, { "pos", pt( v->Pos() ) },
                     { "diameter", v->Diameter( 0 ) }, { "drill", v->Drill() },
                     { "layers", json::array( { v->Layers().Start(), v->Layers().End() } ) } };
        }

        return json();
    }

    void AddItem( PNS::ITEM* aItem ) override
    {
        json j = itemJSON( aItem );

        if( !j.is_null() )
            m_added.push_back( j );
    }

    /// The scene's index of a board item (-1: none, the router's own)
    int indexOf( const PNS::ITEM* aItem ) const
    {
        auto it = std::find( m_byIndex.begin(), m_byIndex.end(), aItem );
        return it == m_byIndex.end() ? -1 : int( it - m_byIndex.begin() );
    }

    /// The board as a branch of the router's world has it: the board's items it takes off (their indices) and the
    /// tracks and vias it puts on, each in one order (what the shove has pushed aside, and where it put it)
    json nodeJSON( PNS::NODE* aNode ) const
    {
        if( !aNode )
            return json();

        PNS::NODE::ITEM_VECTOR removed, added;
        aNode->GetUpdatedItems( removed, added );
        std::vector<int>  indices;
        std::vector<json> items;

        for( const PNS::ITEM* item : removed )
        {
            if( int i = indexOf( item ); i >= 0 )
                indices.push_back( i );
        }

        for( const PNS::ITEM* item : added )
        {
            if( json j = itemJSON( item ); !j.is_null() )
                items.push_back( j );
        }

        std::sort( indices.begin(), indices.end() );
        std::sort( items.begin(), items.end(), []( const json& a, const json& b ) { return a.dump() < b.dump(); } );
        return { { "removed", indices }, { "added", items } };
    }

    /// What the routes took off the board (a shoved track, say): the indices of its items, as the route found them
    std::vector<int> m_removed;

    void UpdateItem( PNS::ITEM* aItem ) override {}

    void RemoveItem( PNS::ITEM* aItem ) override
    {
        if( int i = indexOf( aItem ); i >= 0 )
            m_removed.push_back( i );
    }
    bool IsAnyLayerVisible( const PNS_LAYER_RANGE& aLayer ) const override { return true; }
    bool IsItemVisible( const PNS::ITEM* aItem ) const override { return true; }

    /// Which layers a pad or via of the board is flashed on (PAD::FlashLayer, PCB_VIA::FlashLayer)
    const std::vector<bool>* flashed( const PNS::ITEM* aItem ) const
    {
        const ITEM_INFO* i = m_resolver.info( aItem );
        return i && !i->flashed.empty() && !aItem->OfKind( PNS::ITEM::HOLE_T ) ? &i->flashed : nullptr;
    }

    bool IsFlashedOnLayer( const PNS::ITEM* aItem, int aLayer ) const override
    {
        if( aLayer < 0 )
            return true;

        if( const std::vector<bool>* f = flashed( aItem ) )
            return aLayer < (int) f->size() && ( *f )[aLayer];

        if( aItem->OfKind( PNS::ITEM::VIA_T ) )
            return static_cast<const PNS::VIA*>( aItem )->ConnectsLayer( aLayer );

        return aItem->Layers().Overlaps( aLayer );
    }

    bool IsFlashedOnLayer( const PNS::ITEM* aItem, const PNS_LAYER_RANGE& aLayer ) const override
    {
        PNS_LAYER_RANGE test = aItem->Layers().Intersection( aLayer );

        if( const std::vector<bool>* f = flashed( aItem ) )
        {
            for( int layer = test.Start(); layer <= test.End(); ++layer )
            {
                if( layer >= 0 && layer < (int) f->size() && ( *f )[layer] )
                    return true;
            }

            return false;
        }

        if( aItem->OfKind( PNS::ITEM::VIA_T ) )
        {
            for( int layer = test.Start(); layer <= test.End(); ++layer )
            {
                if( static_cast<const PNS::VIA*>( aItem )->ConnectsLayer( layer ) )
                    return true;
            }

            return false;
        }

        return test.Start() <= test.End();
    }

    bool IsPNSCopperLayer( int aLayer ) const override { return aLayer >= 0 && aLayer < m_layers; }
    void DisplayItem( const PNS::ITEM*, int, bool, int ) override {}
    void DisplayPathLine( const SHAPE_LINE_CHAIN&, int ) override {}
    void DisplayRatline( const SHAPE_LINE_CHAIN&, PNS::NET_HANDLE ) override {}
    void HideItem( PNS::ITEM* ) override {}
    void Commit() override {}
    bool ImportSizes( PNS::SIZES_SETTINGS&, PNS::ITEM*, PNS::NET_HANDLE, VECTOR2D ) override { return false; }
    int StackupHeight( int, int ) const override { return 0; }
    void EraseView() override {}
    int GetNetCode( PNS::NET_HANDLE aNet ) const override { return netCode( aNet ); }
    wxString GetNetName( PNS::NET_HANDLE aNet ) const override { return wxString::Format( "Net-%d", netCode( aNet ) ); }
    void UpdateNet( PNS::NET_HANDLE ) override {}
    PNS::NET_HANDLE GetOrphanedNetHandle() override { return netHandle( 0 ); }
    PNS::NODE* GetWorld() const override { return m_world; }
    PNS::RULE_RESOLVER* GetRuleResolver() override { return &m_resolver; }
    TRACE_DECORATOR*             m_trace = nullptr;

    PNS::DEBUG_DECORATOR* GetDebugDecorator() override { return m_trace; }
    long long int CalculateRoutedPathLength( const PNS::ITEM_SET&, const PNS::SOLID*, const PNS::SOLID*, const NETCLASS* ) override { return 0; }
    int64_t CalculateRoutedPathDelay( const PNS::ITEM_SET&, const PNS::SOLID*, const PNS::SOLID*, const NETCLASS* ) override { return 0; }
    int64_t CalculateLengthForDelay( int64_t, int, bool, int, int, const NETCLASS* ) override { return 0; }
    int64_t CalculateDelayForShapeLineChain( const SHAPE_LINE_CHAIN&, int, bool, int, int, const NETCLASS* ) override { return 0; }

    PCB_LAYER_ID GetBoardLayerFromPNSLayer( int aLayer ) const override
    {
        if( aLayer == 0 )
            return F_Cu;

        if( aLayer == m_layers - 1 )
            return B_Cu;

        return static_cast<PCB_LAYER_ID>( ( aLayer + 1 ) * 2 );
    }

    int GetPNSLayerFromBoardLayer( PCB_LAYER_ID aLayer ) const override
    {
        if( aLayer == F_Cu )
            return 0;

        if( aLayer == B_Cu )
            return m_layers - 1;

        return ( aLayer / 2 ) - 1;
    }
};

/// Whether taking back the last fixed part of a shoving route now (LINE_PLACER::UnfixRoute) would delete a node the
/// shove still keeps on its springback stack: a fix made while the shove had nothing on its stack, taken back before
/// the shove has any, has UnfixRoute kill the children of the shove's root, the locked node of the fix among them.
/// What KiCad's router does after that is undefined (it reads the deleted node), so such a scene is no reference.
static bool undefinedUndo( PNS::LINE_PLACER* aPlacer )
{
    PNS::SHOVE* shove = aPlacer->m_shove.get();

    if( !shove || aPlacer->m_fixedTail.m_stages.empty() )
        return false;

    // what UnfixRoute does: the stack rewound to the last stage's node, then the shove's current node's children
    // killed
    PNS::NODE* commit = aPlacer->m_fixedTail.m_stages.back().commit;
    std::vector<PNS::NODE*> stack;

    for( const auto& tag : shove->m_nodeStack )
        stack.push_back( tag.m_node );

    PNS::NODE* current = shove->CurrentNode();
    auto       found = std::find( stack.begin(), stack.end(), commit );

    if( found != stack.end() )
    {
        stack.erase( found, stack.end() );
        current = stack.empty() ? shove->m_root : stack.back();
    }

    for( PNS::NODE* node : stack )
    {
        for( PNS::NODE* p = node->GetParent(); p; p = p->GetParent() )
        {
            if( p == current )
                return true;
        }
    }

    return false;
}

static json lineJSON( const PNS::LINE& aLine )
{
    json j = { { "points", chainPoints( aLine.CLine() ) }, { "width", aLine.Width() }, { "layer", aLine.Layer() } };

    if( aLine.EndsWithVia() )
        j["via"] = pt( aLine.Via().Pos() );

    return j;
}

/// What a drag has dragged (DRAGGER::Traces): its lines, and its vias as the scene gives them
static json tracesJSON( const PNS::ITEM_SET& aTraces )
{
    json a = json::array();

    for( const PNS::ITEM* item : aTraces.CItems() )
    {
        if( item->Kind() == PNS::ITEM::LINE_T )
            a.push_back( lineJSON( *static_cast<const PNS::LINE*>( item ) ) );
        else
            a.push_back( SCENE_IFACE::itemJSON( item ) );
    }

    return a;
}

/// A drag's steps, as the router tool drives the router's dragger (ROUTER_TOOL::performDragging): each a pointer
/// position, or a click ("fix"; with Ctrl held, "force", which keeps a drag that collides, marking obstacles), which
/// ends the drag when the dragger keeps it. After each, whether the move worked, what it dragged, whether the dragger
/// marks obstacles now (its first move failed) and whether what it dragged is clear, and the board as the dragger has
/// it, when it has changed, for a scene that asks. A last click ("fix" of the route) if the drag is still going on.
static void dragSteps( PNS::ROUTER& aRouter, SCENE_IFACE& aIface, const json& aRoute, json& aMoves, json& aResult,
                       bool aRemoveItems )
{
    bool finished = false;
    json lastNode;

    for( const json& m : aRoute["moves"] )
    {
        json step;

        if( m.is_array() )
        {
            step["moved"] = aRouter.Move( pt( m ), nullptr );
        }
        else if( m.contains( "fix" ) )
        {
            finished = aRouter.FixRoute( pt( m["fix"] ), nullptr, false, m.value( "force", false ) );
            step["fixed"] = finished;
        }

        // (a drag kept is in the world, its branches gone with what the dragger had of them)
        if( !finished )
        {
            PNS::DRAG_ALGO* dragger = aRouter.GetDragger();
            bool            status = false;

            step["forceMark"] = dragger->GetForceMarkObstaclesMode( &status );
            step["status"] = status;
            step["dragged"] = tracesJSON( dragger->Traces() );
            step["layer"] = aRouter.GetCurrentLayer();

            if( aRemoveItems )
            {
                json node = aIface.nodeJSON( dragger->CurrentNode() );

                if( node != lastNode )
                    step["node"] = node;

                lastNode = node;
            }
        }

        aMoves.push_back( step );

        if( finished )
            break;
    }

    if( !finished && aRoute.contains( "fix" ) )
        aResult["fixed"] = aRouter.FixRoute( pt( aRoute["fix"] ), nullptr, false, aRoute.value( "force", false ) );

    aRouter.StopRouting();
}

extern std::function<wxString( const PNS::ITEM* )> g_kicadReferenceNonRoutableReason;

int main()
{
    json scene = json::parse( std::cin );
    SCENE_IFACE iface;

    // Why the router cannot start from a non-routable item, as its BOARD_ITEM would say in ROUTER::
    // isStartingPointRoutable (patch.py has it ask here): a hole with no plating, a rule area, a text
    g_kicadReferenceNonRoutableReason = [&]( const PNS::ITEM* aItem ) -> wxString
    {
        const ITEM_INFO* i = iface.m_resolver.info( aItem );

        if( !i )
            return wxString();
        else if( i->kind == "pad" && i->npth )
            return wxS( "Cannot start routing from a non-plated hole." );
        else if( i->kind == "keepout" && !i->keepout.value( "name", std::string() ).empty() )
            return wxString::Format( wxS( "Rule area '%s' disallows tracks." ), wxString( i->keepout["name"].get<std::string>() ) );
        else if( i->kind == "keepout" )
            return wxS( "Rule area disallows tracks." );
        else if( i->kind == "text" )
            return wxS( "Cannot start routing from a text item." );

        return wxString();
    };
    iface.m_items = scene["items"];
    iface.m_layers = scene.value( "layers", 2 );

    const json& rules = scene["rules"];
    iface.m_resolver.m_clearance = rules.value( "clearance", 200000 );
    iface.m_resolver.m_holeClearance = rules.value( "holeClearance", 250000 );
    iface.m_resolver.m_holeToHole = rules.value( "holeToHole", 250000 );
    iface.m_resolver.m_edgeClearance = rules.value( "edgeClearance", 500000 );
    iface.m_resolver.m_epsilon = rules.value( "epsilon", 0 );

    if( rules.value( "board", false ) )
    {
        iface.m_resolver.m_board = true;
        iface.m_resolver.m_clearance = rules["minClearance"];
        iface.m_maxClearance = rules["maxClearance"];

        for( const auto& [code, clearance] : rules["netClearance"].items() )
            iface.m_resolver.m_netClearance[std::stoi( code )] = clearance;
    }

    TRACE_DECORATOR trace;

    if( getenv( "KICAD_ROUTER_DEBUG" ) )
    {
        trace.SetDebugEnabled( true );
        iface.m_trace = &trace;
    }

    PNS::ROUTER router;
    PNS::ROUTING_SETTINGS settings( nullptr, "" );
    // (no time limit on a shove, set as the router's settings file would set it: it gives up after a second, by the
    // clock, which makes what it does depend on how fast the machine is; it stops on its iteration limit alone)
    settings.Set<int>( "shove_time_limit", std::numeric_limits<int>::max() );
    settings.Load();
    router.SetInterface( &iface );
    router.LoadSettings( &settings );

    json out = json::array();

    // ("removeItems": what each route takes off the board, its tracks and vias shoved aside, is listed ("removed")
    // and gone for the routes after it; else only what the routes add is kept)
    bool removeItems = scene.value( "removeItems", false );

    for( const json& route : scene["routes"] )
    {
        std::string mode = route.value( "mode", "walkaround" );
        settings.SetMode( mode == "mark" ? PNS::RM_MarkObstacles : mode == "shove" ? PNS::RM_Shove : PNS::RM_Walkaround );
        settings.SetOptimizerEffort( PNS::OE_MEDIUM );
        settings.SetSmoothDraggedSegments( route.value( "smooth", true ) );
        settings.SetOptimizeEntireDraggedTrack( route.value( "optimizeEntire", false ) );
        settings.SetAllowDRCViolations( route.value( "allowViolations", false ) );

        // a world fresh from the board, with what the routes before this one added
        router.ClearWorld();
        router.SyncWorld();

        PNS::SIZES_SETTINGS sizes;
        sizes.SetTrackWidth( route.value( "width", 250000 ) );
        sizes.SetViaDiameter( route.value( "viaDiameter", 600000 ) );
        sizes.SetViaDrill( route.value( "viaDrill", 300000 ) );
        sizes.SetClearance( iface.m_resolver.m_clearance );
        router.UpdateSizes( sizes );

        auto itemAt = [&]( const char* aKey, const json& aIn ) -> PNS::ITEM*
        {
            int i = aIn.value( aKey, -1 );
            return i >= 0 && i < (int) iface.m_byIndex.size() ? iface.m_byIndex[i] : nullptr;
        };

        json r;
        iface.m_added.clear();
        iface.m_removed.clear();

        // (with the first route, the keepout zones' triangles as the world has them, if there are any)
        if( out.empty() && !iface.m_triangles.empty() )
            r["keepoutTriangles"] = iface.m_triangles;

        // (a drag: of the item the route names, from where it says, as the router tool's drag (D) or free angle drag
        // (G) starts one; else a track from its start)
        bool dragging = route.contains( "drag" );
        bool started;

        if( dragging )
        {
            const json& d = route["drag"];
            started = router.StartDragging( pt( d["at"] ), itemAt( "item", d ),
                                            d.value( "freeAngle", false ) ? PNS::DM_ANY | PNS::DM_FREE_ANGLE : PNS::DM_ANY );
        }
        else
        {
            started = router.StartRouting( pt( route["start"] ), itemAt( "startItem", route ), route.value( "layer", 0 ) );
        }

        r["started"] = started;

        if( !started )
            r["failure"] = router.FailureReason().ToStdString();

        json moves = json::array();
        json lastNode;

        if( started && dragging )
        {
            dragSteps( router, iface, route, moves, r, removeItems );
        }
        else if( started )
        {
            bool finished = false;

            // each step a pointer position (or one with the item under it, "move" and "endItem"), or one of what the
            // router tool asks of the router: a layer pair for
            // vias ("pair"), via placement on or off ("via"), a layer to route on ("layer"), the posture flipped
            // ("posture"), the route fixed where it is ("fix", which ends it when the router says it is finished),
            // the last fixed part taken back ("undo")
            for( const json& m : route["moves"] )
            {
                json step;

                if( m.is_array() )
                {
                    router.Move( pt( m ), itemAt( "endItem", route ) );
                }
                else if( m.contains( "move" ) )
                {
                    // (a pointer position with the item under it, as the router tool finds one at each move)
                    router.Move( pt( m["move"] ), itemAt( "endItem", m ) );
                }
                else if( m.contains( "pair" ) )
                {
                    PNS::SIZES_SETTINGS s = router.Sizes();
                    s.ClearLayerPairs();
                    s.AddLayerPair( m["pair"][0], m["pair"][1] );
                    router.UpdateSizes( s );
                }
                else if( m.contains( "via" ) )
                {
                    // ("on", as the router tool turns it on: only when it is off)
                    if( m["via"] != "on" || !router.IsPlacingVia() )
                        router.ToggleViaPlacement();
                }
                else if( m.contains( "layer" ) )
                {
                    step["switched"] = router.SwitchLayer( m["layer"] );
                }
                else if( m.contains( "posture" ) )
                {
                    router.FlipPosture();
                }
                else if( m.contains( "fix" ) )
                {
                    // (the item under the pointer: the route's end item, unless the step names another, or none)
                    finished = router.FixRoute( pt( m["fix"] ), itemAt( "endItem", m.contains( "endItem" ) ? m : route ),
                                                false, false );
                    step["fixed"] = finished;
                }
                else if( m.contains( "undo" ) )
                {
                    // (an undo KiCad's code gets wrong: no reference to be had, exit status 3)
                    if( settings.Mode() == PNS::RM_Shove
                        && undefinedUndo( static_cast<PNS::LINE_PLACER*>( router.Placer() ) ) )
                    {
                        std::cerr << "route " << out.size() << ": an undo KiCad's router has no defined result for\n";
                        return 3;
                    }

                    std::optional<VECTOR2I> p = router.UndoLastSegment();
                    step["undone"] = p ? json( pt( *p ) ) : json();
                }

                auto placer = static_cast<PNS::LINE_PLACER*>( router.Placer() );
                step["head"] = lineJSON( placer->Head() );
                step["tail"] = lineJSON( placer->Tail() );
                step["trace"] = lineJSON( placer->Trace() );
                step["layer"] = router.GetCurrentLayer();
                step["placingVia"] = router.IsPlacingVia();

                // (and the board as the router has it now, what it has shoved where, for a scene that asks: when it
                // has changed since the step before)
                if( removeItems )
                {
                    json node = iface.nodeJSON( placer->CurrentNode( true ) );

                    if( node != lastNode )
                        step["node"] = node;

                    lastNode = node;
                }

                moves.push_back( step );

                if( finished )
                    break;
            }

            if( !finished && route.contains( "fix" ) )
            {
                bool done = router.FixRoute( pt( route["fix"] ), itemAt( "endItem", route ), route.value( "forceFinish", false ), false );
                r["fixed"] = done;
            }

            router.CommitRouting();
        }

        // (what the route added, in one order whatever order KiCad's hash set gave it in, for the next route)
        std::sort( iface.m_added.begin(), iface.m_added.end(),
                   []( const json& a, const json& b ) { return a.dump() < b.dump(); } );
        r["moves"] = moves;
        r["added"] = iface.m_added;

        if( removeItems )
        {
            std::sort( iface.m_removed.begin(), iface.m_removed.end() );
            r["removed"] = iface.m_removed;

            for( auto it = iface.m_removed.rbegin(); it != iface.m_removed.rend(); ++it )
                iface.m_items.erase( iface.m_items.begin() + *it );
        }

        out.push_back( r );

        for( const json& a : iface.m_added )
            iface.m_items.push_back( a );
    }

    std::cout << out.dump() << std::endl;
    return 0;
}
