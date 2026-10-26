// KiCad's own geometry (libs/kimath and the router's hulls in pcbnew/router/pns_utils.cpp, KiCad 10.0.7) on random
// cases, written as JSON for KiCadRouterTests: each case's input and what KiCad makes of it, so that the router's Swift
// port can be checked against KiCad to the nanometre. build.sh builds this against KiCad's sources.
//
// This program links KiCad's code: GNU General Public License version 3 or later, as KiCad.

#include <convert_basic_shapes_to_polygon.h>
#include <geometry/direction45.h>
#include <geometry/polygon_triangulation.h>
#include <geometry/seg.h>
#include <geometry/shape_arc.h>
#include <geometry/shape_circle.h>
#include <geometry/shape_line_chain.h>
#include <geometry/shape_poly_set.h>
#include <geometry/shape_rect.h>
#include <geometry/shape_segment.h>
#include <geometry/shape_simple.h>
#include <math/util.h>
#include <trigo.h>
#include <math/vector2d.h>
#include <nlohmann/json.hpp>
#include <pns_line.h>
#include <pns_utils.h>

#include <algorithm>
#include <cstdio>
#include <functional>
#include <iostream>
#include <optional>
#include <random>
#include <sys/wait.h>
#include <unistd.h>

using json = nlohmann::json;

// SHAPE_POLY_SET::splitSelfTouchingOutlines is private: its address is taken in an explicit instantiation, where C++
// does not check access, so that what it makes of a fractured set can be written too
using SPLIT_FN = void ( SHAPE_POLY_SET::* )();
static SPLIT_FN g_splitSelfTouchingOutlines = nullptr;

template <SPLIT_FN F>
struct SPLIT_ACCESS
{
    SPLIT_ACCESS() { g_splitSelfTouchingOutlines = F; }
    static SPLIT_ACCESS instance;
};

template <SPLIT_FN F>
SPLIT_ACCESS<F> SPLIT_ACCESS<F>::instance;

template struct SPLIT_ACCESS<&SHAPE_POLY_SET::splitSelfTouchingOutlines>;

static std::mt19937_64 rng( 20261016 );

static int uniform( int lo, int hi ) { return std::uniform_int_distribution<int>( lo, hi )( rng ); }
static bool chance( int percent ) { return uniform( 0, 99 ) < percent; }

static json pt( const VECTOR2I& p ) { return json::array( { p.x, p.y } ); }
static VECTOR2I ptOf( const json& j ) { return VECTOR2I( j[0].get<int>(), j[1].get<int>() ); }
static json opt( const OPT_VECTOR2I& p ) { return p ? pt( *p ) : json(); }

static json chainPoints( const SHAPE_LINE_CHAIN& c )
{
    json a = json::array();

    for( int i = 0; i < c.PointCount(); i++ )
        a.push_back( pt( c.CPoint( i ) ) );

    return a;
}

/// A point: anywhere in a few millimetres, on a 0.05 mm grid, or near the origin (where the small cases are)
static VECTOR2I randPoint()
{
    switch( uniform( 0, 3 ) )
    {
    case 0: return VECTOR2I( uniform( -3000000, 3000000 ), uniform( -3000000, 3000000 ) );
    case 1: return VECTOR2I( uniform( -60, 60 ) * 50000, uniform( -60, 60 ) * 50000 );
    case 2: return VECTOR2I( uniform( -20, 20 ), uniform( -20, 20 ) );
    default: return VECTOR2I( uniform( -400000, 400000 ), uniform( -400000, 400000 ) );
    }
}

/// A point from `a` along one of the 45° directions, or nearly one, or anywhere
static VECTOR2I randFrom( const VECTOR2I& a )
{
    int l = chance( 20 ) ? uniform( 0, 12 ) : uniform( 1, 2000000 );

    switch( uniform( 0, 5 ) )
    {
    case 0: return a + VECTOR2I( l * ( chance( 50 ) ? 1 : -1 ), 0 );
    case 1: return a + VECTOR2I( 0, l * ( chance( 50 ) ? 1 : -1 ) );
    case 2: return a + VECTOR2I( l * ( chance( 50 ) ? 1 : -1 ), l * ( chance( 50 ) ? 1 : -1 ) );
    case 3: return a + VECTOR2I( l + uniform( -2, 2 ), l * ( chance( 50 ) ? 1 : -1 ) + uniform( -2, 2 ) );
    case 4: return a;
    default: return randPoint();
    }
}

static SEG randSeg()
{
    VECTOR2I a = randPoint();
    return SEG( a, randFrom( a ) );
}

/// A segment related to `s`: crossing it, along it, touching its end, parallel to it, or anywhere
static SEG relatedSeg( const SEG& s )
{
    switch( uniform( 0, 5 ) )
    {
    case 0: return SEG( s.A, randFrom( s.A ) );
    case 1: return SEG( s.B, randFrom( s.B ) );
    case 2:
    {
        VECTOR2I d = s.B - s.A;
        VECTOR2I off = VECTOR2I( uniform( -5, 5 ), uniform( -5, 5 ) ) * ( chance( 50 ) ? 1 : 1000 );
        return SEG( s.A + off + d / 3, s.B + off + d / 2 );
    }
    case 3:
    {
        VECTOR2I c = s.Center();
        return SEG( c + VECTOR2I( uniform( -500000, 500000 ), uniform( -500000, 500000 ) ),
                    c - VECTOR2I( uniform( -500000, 500000 ), uniform( -500000, 500000 ) ) );
    }
    case 4: return SEG( s.B, s.A );
    default: return randSeg();
    }
}

static SHAPE_LINE_CHAIN randChain( bool aClosed )
{
    SHAPE_LINE_CHAIN c;
    int n = uniform( aClosed ? 3 : 2, 8 );
    VECTOR2I p = randPoint();
    c.Append( p );

    // (points repeated now and then, but always enough apart for a segment, or a polygon)
    while( c.PointCount() < n || c.CPoint( 0 ) == c.CLastPoint() )
    {
        p = chance( 85 ) ? randFrom( p ) : randPoint();
        c.Append( p, chance( 10 ) && c.PointCount() < n );
    }

    c.SetClosed( aClosed );
    return c;
}

/// A convex polygon: points round a centre, in angle order
static SHAPE_SIMPLE randConvex()
{
    VECTOR2I c = randPoint();
    int n = uniform( 3, 8 );
    int r = uniform( 10000, 1500000 );
    std::vector<double> angles;

    for( int i = 0; i < n; i++ )
        angles.push_back( std::uniform_real_distribution<double>( 0, 2 * M_PI )( rng ) );

    std::sort( angles.begin(), angles.end() );
    SHAPE_SIMPLE s;

    for( double a : angles )
        s.Append( c.x + KiROUND( r * cos( a ) ), c.y + KiROUND( r * sin( a ) ) );

    return s;
}

static json shapeJSON( const SHAPE* s )
{
    switch( s->Type() )
    {
    case SH_CIRCLE:
    {
        auto c = static_cast<const SHAPE_CIRCLE*>( s );
        return { { "circle", pt( c->GetCenter() ) }, { "r", c->GetRadius() } };
    }
    case SH_RECT:
    {
        auto r = static_cast<const SHAPE_RECT*>( s );
        return { { "rect", pt( r->GetPosition() ) }, { "size", pt( r->GetSize() ) } };
    }
    case SH_SEGMENT:
    {
        auto g = static_cast<const SHAPE_SEGMENT*>( s );
        return { { "segment", json::array( { pt( g->GetSeg().A ), pt( g->GetSeg().B ) } ) },
                 { "w", g->GetWidth() } };
    }
    case SH_SIMPLE:
        return { { "simple", chainPoints( static_cast<const SHAPE_SIMPLE*>( s )->Vertices() ) } };
    case SH_LINE_CHAIN:
        return { { "chain", chainPoints( *static_cast<const SHAPE_LINE_CHAIN*>( s ) ) } };
    case SH_ARC:
    {
        auto a = static_cast<const SHAPE_ARC*>( s );
        return { { "arc", json::array( { pt( a->GetP0() ), pt( a->GetArcMid() ), pt( a->GetP1() ) } ) },
                 { "w", a->GetWidth() } };
    }
    default:
        return json();
    }
}

static SHAPE* randShape( bool aWithChain )
{
    switch( uniform( 0, aWithChain ? 4 : 3 ) )
    {
    case 0: return new SHAPE_CIRCLE( randPoint(), uniform( 1, 1200000 ) );
    case 1:
    {
        VECTOR2I p = randPoint();
        return new SHAPE_RECT( p, uniform( 0, 2000000 ), uniform( 0, 2000000 ) );
    }
    case 2:
    {
        SEG s = randSeg();
        return new SHAPE_SEGMENT( s.A, s.B, uniform( 0, 1000000 ) );
    }
    case 3: return new SHAPE_SIMPLE( randConvex() );
    default: return new SHAPE_LINE_CHAIN( randChain( false ) );
    }
}

/// A shape near `a`, so that many pairs come close
static SHAPE* nearShape( const SHAPE* a, bool aWithChain )
{
    SHAPE* b = randShape( aWithChain );

    if( chance( 70 ) )
    {
        VECTOR2I to = a->Centre() + VECTOR2I( uniform( -1500000, 1500000 ), uniform( -1500000, 1500000 ) );
        b->Move( to - b->Centre() );
    }

    return b;
}

/// An angle, often one of the eighths of a turn, a full turn or close to none
static EDA_ANGLE randAngle()
{
    switch( uniform( 0, 5 ) )
    {
    case 0: return EDA_ANGLE( uniform( -8, 8 ) * 45.0, DEGREES_T );
    case 1: return EDA_ANGLE( chance( 50 ) ? 360.0 : -360.0, DEGREES_T );
    case 2: return EDA_ANGLE( std::uniform_real_distribution<double>( -2, 2 )( rng ), DEGREES_T );
    default: return EDA_ANGLE( std::uniform_real_distribution<double>( -359, 359 )( rng ), DEGREES_T );
    }
}

/// An arc: about a centre from a start through an angle, through three points round a circle, all but straight,
/// or through any three points; of no width now and then
static SHAPE_ARC randArcAny()
{
    int w = chance( 30 ) ? 0 : uniform( 1, 1000000 );
    VECTOR2I c = randPoint();
    int r = chance( 10 ) ? uniform( 1, 50 ) : chance( 10 ) ? uniform( 5000000, 400000000 ) : uniform( 100, 2000000 );

    switch( uniform( 0, 4 ) )
    {
    case 0:
    {
        VECTOR2I start = c + VECTOR2I( r, 0 );
        RotatePoint( start, c, randAngle() );
        return SHAPE_ARC( c, start, randAngle(), w );
    }
    case 1:
    {
        double a0 = std::uniform_real_distribution<double>( 0, 2 * M_PI )( rng );
        double da = std::uniform_real_distribution<double>( -2 * M_PI, 2 * M_PI )( rng );
        auto at = [&]( double a ) { return c + VECTOR2I( KiROUND( r * cos( a ) ), KiROUND( r * sin( a ) ) ); };
        return SHAPE_ARC( at( a0 ), at( a0 + da / 2 ), at( a0 + da ), w );
    }
    case 2:
    {
        VECTOR2I a = randPoint();
        VECTOR2I b = randFrom( a );
        VECTOR2I m = ( a + b ) / 2 + VECTOR2I( uniform( -3, 3 ), uniform( -3, 3 ) );
        return SHAPE_ARC( a, m, b, w );
    }
    case 3:
    {
        VECTOR2I a = randPoint();
        return SHAPE_ARC( a, randFrom( a ), randPoint(), w );
    }
    default:
    {
        VECTOR2I start = c + VECTOR2I( r, 0 );
        RotatePoint( start, c, randAngle() );
        VECTOR2I end = c + VECTOR2I( r, 0 );
        RotatePoint( end, c, randAngle() );
        SHAPE_ARC arc;

        if( chance( 50 ) )
            arc.ConstructFromStartEndCenter( start, end, c, chance( 50 ) );
        else
            arc.ConstructFromStartEndAngle( start, end, randAngle() );

        arc.SetWidth( w );
        return arc;
    }
    }
}

/// An arc whose radius is less than half a metre. (Beyond, KiCad's arithmetic on its centre runs out of what an
/// int holds and wraps; no board has such an arc but one all but straight, which KiCad takes as a segment.)
static SHAPE_ARC randArc()
{
    for( ;; )
    {
        SHAPE_ARC arc = randArcAny();

        if( arc.GetRadius() < 5e8 )
            return arc;
    }
}

static json intersections( const SHAPE_LINE_CHAIN::INTERSECTIONS& ips )
{
    json a = json::array();

    for( const SHAPE_LINE_CHAIN::INTERSECTION& x : ips )
    {
        a.push_back( { { "p", pt( x.p ) }, { "our", x.index_our }, { "their", x.index_their },
                       { "cornerOur", x.is_corner_our }, { "cornerTheir", x.is_corner_their },
                       { "valid", x.valid } } );
    }

    return a;
}

/// What `run` writes, run in a child process: nothing if the child dies. (Clipper2 has inputs it goes round for ever
/// on, recursing until its stack runs out, as clipper.cpp finds; Simplify's union might meet one. Such a case is kept,
/// marked as one KiCad crashes on.)
static std::optional<std::string> isolated( const std::function<std::string()>& run )
{
    int fds[2];

    if( pipe( fds ) != 0 )
        abort();

    std::cout.flush();
    pid_t pid = fork();

    if( pid == 0 )
    {
        close( fds[0] );
        std::string out = run();

        for( size_t at = 0; at < out.size(); )
        {
            ssize_t n = write( fds[1], out.data() + at, out.size() - at );

            if( n <= 0 )
                _exit( 1 );

            at += n;
        }

        _exit( 0 );
    }

    close( fds[1] );
    std::string out;
    char        buffer[65536];

    for( ssize_t n; ( n = read( fds[0], buffer, sizeof buffer ) ) > 0; )
        out.append( buffer, n );

    close( fds[0] );
    int status = 0;
    waitpid( pid, &status, 0 );

    if( !WIFEXITED( status ) || WEXITSTATUS( status ) != 0 )
        return std::nullopt;

    return out;
}

/// A polygon set's polygons, each its outline's points and then each hole's
static json polySetJSON( const SHAPE_POLY_SET& aSet )
{
    json a = json::array();

    for( int i = 0; i < aSet.OutlineCount(); i++ )
    {
        json polygon = json::array();

        for( const SHAPE_LINE_CHAIN& chain : aSet.CPolygon( i ) )
            polygon.push_back( chainPoints( chain ) );

        a.push_back( polygon );
    }

    return a;
}

/// A polygon set's case: what Simplify and Fracture make of it, the fractured outlines split where they touch
/// themselves, and the triangles CacheTriangulation( false ) cuts it into (in a child process: a case KiCad crashes on
/// is marked so)
static json polySetCase( int aKind, const json& aPolys, const SHAPE_POLY_SET& aSet )
{
    json j = { { "kind", aKind }, { "polys", aPolys } };

    std::optional<std::string> result = isolated(
            [&]() -> std::string
            {
                json r;
                SHAPE_POLY_SET simplified( aSet );
                simplified.Simplify();
                r["simplified"] = polySetJSON( simplified );
                SHAPE_POLY_SET fractured( aSet );
                fractured.ClearArcs();
                fractured.Fracture();
                r["fractured"] = polySetJSON( fractured );
                ( fractured.*g_splitSelfTouchingOutlines )();
                r["split"] = polySetJSON( fractured );
                SHAPE_POLY_SET triangulated( aSet );
                triangulated.CacheTriangulation( false );
                r["upToDate"] = triangulated.IsTriangulationUpToDate();
                json tris = json::array();

                for( unsigned k = 0; k < triangulated.TriangulatedPolyCount(); k++ )
                {
                    const SHAPE_POLY_SET::TRIANGULATED_POLYGON* tp = triangulated.TriangulatedPolygon( k );
                    json verts = json::array(), ts = json::array();

                    for( const VECTOR2I& v : tp->Vertices() )
                        verts.push_back( pt( v ) );

                    for( const SHAPE_POLY_SET::TRIANGULATED_POLYGON::TRI& t : tp->Triangles() )
                        ts.push_back( json::array( { t.a, t.b, t.c } ) );

                    tris.push_back( { { "source", tp->GetSourceOutlineIndex() }, { "vertices", verts },
                                      { "triangles", ts } } );
                }

                r["triangulated"] = tris;
                return r.dump();
            } );

    if( result )
        j.update( json::parse( *result ) );
    else
        j["crashed"] = true;

    return j;
}

/// A chain's points begun at another of them, and either way round
static std::vector<VECTOR2I> turned( std::vector<VECTOR2I> aPoints )
{
    if( aPoints.size() > 1 )
    {
        int start = uniform( 0, (int) aPoints.size() - 1 );
        std::rotate( aPoints.begin(), aPoints.begin() + start, aPoints.end() );
    }

    if( chance( 50 ) )
        std::reverse( aPoints.begin(), aPoints.end() );

    return aPoints;
}

static std::vector<VECTOR2I> boxPoints( const VECTOR2I& aMin, const VECTOR2I& aMax )
{
    return { aMin, VECTOR2I( aMax.x, aMin.y ), aMax, VECTOR2I( aMin.x, aMax.y ) };
}

/// `aCount` points round `aCentre`, `aRadius` from it (or between a third of that and it, a star), at angles evenly
/// apart or at random, in order
static std::vector<VECTOR2I> roundPoints( const VECTOR2I& aCentre, int aRadius, int aCount, bool aStar, bool aEven )
{
    std::vector<double> angles;

    for( int j = 0; j < aCount; j++ )
        angles.push_back( aEven ? 2 * M_PI * j / aCount : std::uniform_real_distribution<double>( 0, 2 * M_PI )( rng ) );

    std::sort( angles.begin(), angles.end() );
    std::vector<VECTOR2I> pts;

    for( double a : angles )
    {
        int r = aStar ? uniform( std::max( 1, aRadius / 3 ), std::max( 1, aRadius ) ) : aRadius;
        pts.push_back( aCentre + VECTOR2I( KiROUND( r * cos( a ) ), KiROUND( r * sin( a ) ) ) );
    }

    return pts;
}

/// A small step anywhere within `aReach` on each axis
static VECTOR2I jitter( int aReach )
{
    int dx = uniform( -aReach, aReach );
    int dy = uniform( -aReach, aReach );
    return VECTOR2I( dx, dy );
}

/// A chain with arcs as JSON: its points, the arcs each is on, and its arcs (their three points, the centre KiCad
/// keeps, which an arc turned round keeps from before, and their width)
static json arcChainJSON( const SHAPE_LINE_CHAIN& c )
{
    json shapes = json::array();
    json arcs = json::array();

    for( const std::pair<ssize_t, ssize_t>& sh : c.CShapes() )
        shapes.push_back( json::array( { sh.first, sh.second } ) );

    for( const SHAPE_ARC& a : c.CArcs() )
    {
        arcs.push_back( json::array( { pt( a.GetP0() ), pt( a.GetArcMid() ), pt( a.GetP1() ), pt( a.GetCenter() ),
                                       a.GetWidth() } ) );
    }

    return { { "points", chainPoints( c ) }, { "shapes", shapes }, { "arcs", arcs }, { "closed", c.IsClosed() } };
}

/// The steps a chain of segments and arcs is made of, as a track has them: from `aStart`, each a point (along a 45°
/// direction or not, now and then the same point again) or an arc from where the chain is, a turn about a centre near
/// by (now and then one too small to keep as an arc; one after another, so that they share the point between them);
/// a closed one's last now and then an arc back to where it started
static json randArcSteps( const VECTOR2I& aStart, bool aClosed )
{
    json     steps = json::array();
    VECTOR2I p = aStart;
    int      n = uniform( 1, 6 );

    steps.push_back( { { "p", pt( p ) } } );

    for( int i = 0; i < n; i++ )
    {
        if( aClosed && i == n - 1 && p != aStart && chance( 40 ) )
        {
            VECTOR2I d = aStart - p;
            VECTOR2I m = ( p + aStart ) / 2 + VECTOR2I( -d.y, d.x ) * uniform( -9, 9 ) / 10;
            steps.push_back( { { "arc", json::array( { pt( p ), pt( m ), pt( aStart ) } ) } } );
            p = aStart;
        }
        else if( chance( 55 ) )
        {
            int       r = chance( 8 ) ? uniform( 1, 3000 ) : uniform( 20000, 3000000 );
            EDA_ANGLE dir = chance( 50 ) ? EDA_ANGLE( uniform( 0, 7 ) * 45.0, DEGREES_T )
                                         : EDA_ANGLE( std::uniform_real_distribution<double>( 0, 360 )( rng ), DEGREES_T );
            EDA_ANGLE a = chance( 50 ) ? EDA_ANGLE( uniform( -6, 6 ) * 45.0, DEGREES_T )
                                       : EDA_ANGLE( std::uniform_real_distribution<double>( -300, 300 )( rng ), DEGREES_T );

            if( a.AsDegrees() == 0.0 )
                a = ANGLE_90;

            VECTOR2I c = p + VECTOR2I( r, 0 );
            RotatePoint( c, p, dir );
            SHAPE_ARC arc( c, p, a );
            steps.push_back( { { "arc", json::array( { pt( arc.GetP0() ), pt( arc.GetArcMid() ), pt( arc.GetP1() ) } ) } } );
            p = arc.GetP1();
        }
        else
        {
            p = chance( 85 ) ? randFrom( p ) : randPoint();
            steps.push_back( { { "p", pt( p ) }, { "dup", chance( 10 ) } } );
        }
    }

    // (a chain of one point given a second)
    if( steps.size() == 1 )
        steps.push_back( { { "p", pt( p + VECTOR2I( 100000, 0 ) ) } } );

    return steps;
}

/// The chain `randArcSteps` describes, built as KiCad builds one: points appended, arcs appended as arcs
static SHAPE_LINE_CHAIN arcStepsChain( const json& aSteps, bool aClosed )
{
    SHAPE_LINE_CHAIN c;

    for( const json& s : aSteps )
    {
        if( s.contains( "arc" ) )
            c.Append( SHAPE_ARC( ptOf( s["arc"][0] ), ptOf( s["arc"][1] ), ptOf( s["arc"][2] ), 0 ) );
        else
            c.Append( ptOf( s["p"] ), s.value( "dup", false ) );
    }

    c.SetClosed( aClosed );
    return c;
}

/// A point on the chain: one of its points, a point along one of its segments (an arc's too), or near it
static VECTOR2I pointOn( const SHAPE_LINE_CHAIN& c )
{
    switch( uniform( 0, 2 ) )
    {
    case 0: return c.CPoint( uniform( 0, c.PointCount() - 1 ) );
    case 1:
    {
        if( c.SegmentCount() < 1 )
            return c.CPoint( 0 );

        SEG     s = c.CSegment( uniform( 0, c.SegmentCount() - 1 ) );
        int64_t t = uniform( 0, 1000 );
        return VECTOR2I( s.A.x + int( ( s.B.x - s.A.x ) * t / 1000 ), s.A.y + int( ( s.B.y - s.A.y ) * t / 1000 ) );
    }
    default: return c.CPoint( uniform( 0, c.PointCount() - 1 ) ) + jitter( chance( 50 ) ? 3 : 300000 );
    }
}

/// kicad-geometry --arcs COUNT [SEED]: chains with arcs in them as the router keeps its lines (SHAPE_LINE_CHAIN's
/// arcs: each chain built from points and arcs, then cut, split, spliced, turned round, simplified, collided and
/// walked round, each in a child process, as an assertion of KiCad's might stop it), and the traces DIRECTION_45 starts
/// in each corner mode, rounded too
static int arcGeometry( int n )
{
    json out;
    json chains = json::array();

    for( int i = 0; i < n * 2; i++ )
    {
        bool             closed = chance( 25 );
        json             steps = randArcSteps( randPoint(), closed );
        SHAPE_LINE_CHAIN c = arcStepsChain( steps, closed );
        int              pc = c.PointCount();

        // what each operation is asked, drawn here, before the child runs them
        int      s1 = uniform( 0, pc - 1 ), e1 = uniform( s1, pc - 1 );
        int      s2 = uniform( 0, pc - 1 ), e2 = uniform( s2, pc - 1 );
        int      s3 = uniform( 0, pc - 1 ), e3 = uniform( s3, pc - 1 );
        int      shapeAt = uniform( 0, pc - 1 );
        int      insertAt = uniform( 0, pc );
        VECTOR2I insertP = randFrom( c.CPoint( insertAt % pc ) );
        VECTOR2I splitP = pointOn( c );
        bool     splitExact = chance( 30 );
        int      setAt = uniform( 0, pc - 1 );
        VECTOR2I setP = randFrom( c.CPoint( setAt ) );
        int      tol = chance( 50 ) ? 0 : uniform( 1, 50 );
        json     withSteps = randArcSteps( chance( 50 ) ? c.CPoint( s3 ) : randPoint(), false );
        json     appendSteps = randArcSteps( chance( 60 ) ? c.CLastPoint() : randPoint(), false );
        VECTOR2I nearP = pointOn( c ) + jitter( 400000 );
        VECTOR2I collideP = pointOn( c ) + jitter( 600000 );
        int      cl = chance( 10 ) ? 0 : uniform( 0, 500000 );
        SEG      collideS( pointOn( c ) + jitter( 800000 ), pointOn( c ) + jitter( 800000 ) );
        VECTOR2I splitA = pointOn( c ), splitB = pointOn( c );
        json     otherSteps;
        std::unique_ptr<SHAPE> other;

        switch( uniform( 0, 2 ) )
        {
        case 0:
            otherSteps = randArcSteps( pointOn( c ) + jitter( 1000000 ), chance( 20 ) );
            break;
        case 1: other.reset( new SHAPE_ARC( randArc() ) ); break;
        default: other.reset( randShape( false ) ); break;
        }

        if( other && chance( 70 ) )
            other->Move( pointOn( c ) + jitter( 800000 ) - other->Centre() );

        bool otherClosed = !otherSteps.is_null() && chance( 20 );

        std::optional<std::string> result = isolated(
                [&]() -> std::string
                {
                    json j = { { "steps", steps }, { "closed", closed }, { "chain", arcChainJSON( c ) } };
                    json query = json::array();

                    for( int k = 0; k < pc; k++ )
                    {
                        query.push_back( json::array( { c.IsSharedPt( k ), c.IsPtOnArc( k ), c.IsArcSegment( k ),
                                                        c.IsArcStart( k ), c.IsArcEnd( k ), c.ArcIndex( k ),
                                                        c.NextShape( k ) } ) );
                    }

                    j["query"] = query;
                    j["shapeCount"] = c.ShapeCount();
                    j["length"] = c.Length();
                    j["reverse"] = arcChainJSON( c.Reverse() );
                    j["slice"] = { { "s", s1 }, { "e", e1 }, { "result", arcChainJSON( c.Slice( s1, e1 ) ) } };

                    SHAPE_LINE_CHAIN r = c;
                    r.Remove( s2, e2 );
                    j["remove"] = { { "s", s2 }, { "e", e2 }, { "result", arcChainJSON( r ) } };

                    r = c;
                    r.RemoveShape( shapeAt );
                    j["removeShape"] = { { "i", shapeAt }, { "result", arcChainJSON( r ) } };

                    r = c;
                    r.Replace( s3, e3, arcStepsChain( withSteps, false ) );
                    j["replace"] = { { "s", s3 }, { "e", e3 }, { "with", withSteps }, { "result", arcChainJSON( r ) } };

                    r = c;
                    r.Insert( insertAt, insertP );
                    j["insert"] = { { "i", insertAt }, { "p", pt( insertP ) }, { "result", arcChainJSON( r ) } };

                    r = c;
                    r.Append( arcStepsChain( appendSteps, false ) );
                    j["append"] = { { "with", appendSteps }, { "result", arcChainJSON( r ) } };

                    r = c;
                    int at = r.Split( splitP, splitExact );
                    j["split"] = { { "p", pt( splitP ) }, { "exact", splitExact }, { "index", at },
                                   { "result", arcChainJSON( r ) } };

                    r = c;
                    r.SetPoint( setAt, setP );
                    j["setPoint"] = { { "i", setAt }, { "p", pt( setP ) }, { "result", arcChainJSON( r ) } };

                    r = c;
                    r.Simplify( tol );
                    j["simplify"] = { { "tol", tol }, { "result", arcChainJSON( r ) } };
                    r = c;
                    r.Simplify2( true );
                    j["simplify2"] = arcChainJSON( r );
                    r = c;
                    r.Simplify2( false );
                    j["simplify2KeepColinear"] = arcChainJSON( r );
                    r = c;
                    r.RemoveDuplicatePoints();
                    j["removeDuplicates"] = arcChainJSON( r );
                    r = c;
                    r.ClearArcs();
                    j["clearArcs"] = arcChainJSON( r );
                    r = c;
                    r.SetClosed( !closed );
                    j["setClosed"] = arcChainJSON( r );

                    j["nearest"] = { { "p", pt( nearP ) }, { "any", pt( c.NearestPoint( nearP ) ) } };

                    // (an arc's ends only: of an open chain, as KiCad's meander placers ask it, a closed one's last
                    // segment reading past its points)
                    if( !closed )
                        j["nearest"]["ends"] = pt( c.NearestPoint( nearP, false ) );

                    int  actualP = -1, actualS = -1;
                    bool hitP = c.Collide( collideP, cl, &actualP );
                    bool hitS = c.Collide( collideS, cl, &actualS );
                    j["collide"] = { { "cl", cl }, { "p", pt( collideP ) }, { "hitP", hitP },
                                     { "actualP", hitP ? actualP : -1 },
                                     { "s", json::array( { pt( collideS.A ), pt( collideS.B ) } ) },
                                     { "hitS", hitS }, { "actualS", hitS ? actualS : -1 },
                                     { "hitSNoActual", c.Collide( collideS, cl ) } };

                    SHAPE_LINE_CHAIN otherChain;
                    const SHAPE*     o = other.get();

                    if( !o )
                    {
                        otherChain = arcStepsChain( otherSteps, otherClosed );
                        o = &otherChain;
                    }

                    int  actualO = -1;
                    bool hitO = static_cast<const SHAPE*>( &c )->Collide( o, cl, &actualO );
                    int  actualR = -1;
                    bool hitR = o->Collide( &c, cl, &actualR );
                    json shape = { { "steps", otherSteps }, { "closed", otherClosed } };

                    if( other )
                        shape = shapeJSON( o );

                    j["collideShape"] = { { "shape", shape }, { "hit", hitO }, { "actual", hitO ? actualO : -1 },
                                          { "hitNoActual", static_cast<const SHAPE*>( &c )->Collide( o, cl ) },
                                          { "hitReversed", hitR }, { "actualReversed", hitR ? actualR : -1 },
                                          { "hitReversedNoActual", o->Collide( &c, cl ) } };

                    if( !closed )
                    {
                        SHAPE_LINE_CHAIN pre, mid, post;
                        c.Split( splitA, splitB, pre, mid, post );
                        j["splitAt"] = { { "a", pt( splitA ) }, { "b", pt( splitB ) }, { "pre", arcChainJSON( pre ) },
                                         { "mid", arcChainJSON( mid ) }, { "post", arcChainJSON( post ) } };
                    }

                    return j.dump();
                } );

        // (a chain KiCad's own code stops on, an assertion of its failing: no reference)
        if( result )
            chains.push_back( json::parse( *result ) );
    }

    out["chains"] = chains;

    // the traces DIRECTION_45 starts, in each corner mode
    json traces = json::array();

    for( int i = 0; i < n * 4; i++ )
    {
        VECTOR2I     v = chance( 50 ) ? randFrom( VECTOR2I( 0, 0 ) ) : randPoint();
        VECTOR2I     p0 = randPoint();
        VECTOR2I     p1 = chance( 80 ) ? randFrom( p0 ) : randPoint();
        DIRECTION_45 d( v );
        DIRECTION_45 u;
        bool         undefined = chance( 30 );
        bool         diag = chance( 50 );
        int          mode = uniform( 0, 3 );
        SHAPE_LINE_CHAIN trace = ( undefined ? u : d ).BuildInitialTrace( p0, p1, diag,
                                                                       static_cast<DIRECTION_45::CORNER_MODE>( mode ) );
        traces.push_back( { { "v", undefined ? json() : pt( v ) }, { "p0", pt( p0 ) }, { "p1", pt( p1 ) },
                            { "diag", diag }, { "mode", mode }, { "trace", arcChainJSON( trace ) } } );
    }

    out["traces"] = traces;

    // paths with arcs walked round a hull (LINE::Walkaround), both ways: what the walk leaves of the path as it was
    // keeps its arcs
    json walks = json::array();

    for( int i = 0; i < n * 2; i++ )
    {
        std::unique_ptr<SHAPE> a( randShape( false ) );
        int                    cl = uniform( 0, 400000 );
        int                    thickness = uniform( 1, 600000 );
        SHAPE_LINE_CHAIN       hull = PNS::BuildHullForPrimitiveShape( a.get(), cl, thickness );
        BOX2I                  bb = hull.BBox();
        VECTOR2I               start = bb.GetOrigin() - VECTOR2I( uniform( 1, 800000 ), uniform( -800000, 1600000 ) );
        json                   steps = randArcSteps( start, false );
        VECTOR2I               end = chance( 60 ) ? bb.GetEnd() + VECTOR2I( uniform( 1, 800000 ), uniform( -1600000, 800000 ) )
                                                  : bb.Centre() + jitter( std::max<int>( 1, bb.GetWidth() / 3 ) );

        steps.push_back( { { "p", pt( end ) } } );

        if( chance( 50 ) )
        {
            // and on, an arc after it
            json more = randArcSteps( end, false );
            more.erase( more.begin() );

            for( json& s : more )
                steps.push_back( s );
        }

        std::optional<std::string> result = isolated(
                [&]() -> std::string
                {
                    SHAPE_LINE_CHAIN path = arcStepsChain( steps, false );
                    PNS::LINE        line;
                    line.SetShape( path );
                    line.SetWidth( thickness );
                    json results = json::array();

                    for( int cw = 0; cw < 2; cw++ )
                    {
                        SHAPE_LINE_CHAIN walked;
                        bool             ok = line.Walkaround( hull, walked, cw == 1 );
                        results.push_back( { { "ok", ok }, { "path", ok ? arcChainJSON( walked ) : json() } } );
                    }

                    json j = { { "hull", chainPoints( hull ) }, { "steps", steps }, { "ccw", results[0] },
                               { "cw", results[1] } };
                    return j.dump();
                } );

        if( result )
            walks.push_back( json::parse( *result ) );
    }

    out["walkarounds"] = walks;

    // a line's arc dragged through a point (LINE::DragArc, as the dragger drags an arc track): the point near the
    // arc, inside it or out, or far off
    json drags = json::array();

    for( int i = 0; i < n * 2; i++ )
    {
        json             steps = randArcSteps( randPoint(), false );
        SHAPE_LINE_CHAIN path = arcStepsChain( steps, false );
        std::vector<int> onArcs;

        for( int k = 0; k < path.PointCount(); k++ )
        {
            if( path.ArcIndex( k ) >= 0 )
                onArcs.push_back( k );
        }

        if( onArcs.empty() )
            continue;

        int              index = onArcs[uniform( 0, (int) onArcs.size() - 1 )];
        const SHAPE_ARC& arc = path.Arc( path.ArcIndex( index ) );
        VECTOR2I         toward = chance( 50 ) ? arc.GetCenter() : arc.GetArcMid() * 2 - arc.GetCenter();
        VECTOR2I         p = arc.GetArcMid() + ( toward - arc.GetArcMid() ) * uniform( 0, 10 ) / 10 + jitter( 200000 );

        if( chance( 10 ) )
            p = randPoint();

        std::optional<std::string> result = isolated(
                [&]() -> std::string
                {
                    PNS::LINE line;
                    line.SetShape( path );
                    line.SetWidth( 250000 );
                    line.DragArc( p, index );
                    json j = { { "steps", steps }, { "index", index }, { "p", pt( p ) },
                               { "result", arcChainJSON( line.CLine() ) } };
                    return j.dump();
                } );

        if( result )
            drags.push_back( json::parse( *result ) );
    }

    out["arcDrags"] = drags;

    std::cout << out.dump() << std::endl;
    return 0;
}

int main( int argc, char** argv )
{
    // geometry --arcs COUNT [SEED]: chains with arcs, and traces in every corner mode
    if( argc > 1 && std::string( argv[1] ) == "--arcs" )
    {
        if( argc > 3 )
            rng.seed( strtoull( argv[3], nullptr, 10 ) );
        else
            rng.seed( 20261101 );

        return arcGeometry( argc > 2 ? atoi( argv[2] ) : 100 );
    }

    // geometry [COUNT [SEED]]: COUNT cases of each kind, from the random cases SEED gives (the same each time)
    int n = argc > 1 ? atoi( argv[1] ) : 400;

    if( argc > 2 )
        rng.seed( strtoull( argv[2], nullptr, 10 ) );

    json out;

    // vectors: norm, resize, rescale
    json vectors = json::array();

    for( int i = 0; i < n; i++ )
    {
        VECTOR2I v = randFrom( VECTOR2I( 0, 0 ) );
        int l = chance( 20 ) ? uniform( -1000, 1000 ) : uniform( -3000000, 3000000 );
        vectors.push_back( { { "v", pt( v ) }, { "l", l }, { "norm", v.EuclideanNorm() },
                             { "resized", pt( v.Resize( l ) ) } } );
    }

    out["vectors"] = vectors;

    json rescales = json::array();

    for( int i = 0; i < n; i++ )
    {
        auto big = []() -> int64_t
        {
            switch( uniform( 0, 2 ) )
            {
            case 0: return std::uniform_int_distribution<int64_t>( -4000000000000LL, 4000000000000LL )( rng );
            case 1: return uniform( -3000000, 3000000 );
            default: return uniform( -9, 9 );
            }
        };

        int64_t a = big(), b = big(), c = big();

        if( c == 0 )
            c = 7;

        rescales.push_back( { { "a", a }, { "b", b }, { "c", c }, { "r", rescale( a, b, c ) } } );
    }

    out["rescales"] = rescales;

    // segments
    json segs = json::array();

    for( int i = 0; i < n * 4; i++ )
    {
        SEG s = randSeg();
        SEG t = relatedSeg( s );
        VECTOR2I p = chance( 30 ) ? randFrom( s.A ) : randPoint();
        int cl = chance( 20 ) ? uniform( 0, 10 ) : uniform( 0, 600000 );
        int actual = -1;
        bool collide = s.Collide( t, cl, &actual );

        segs.push_back( {
                { "s", json::array( { pt( s.A ), pt( s.B ) } ) },
                { "t", json::array( { pt( t.A ), pt( t.B ) } ) },
                { "p", pt( p ) },
                { "cl", cl },
                { "length", s.Length() },
                { "center", pt( s.Center() ) },
                { "side", s.Side( p ) },
                { "nearest", pt( s.NearestPoint( p ) ) },
                { "nearestSeg", pt( s.NearestPoint( t ) ) },
                { "project", pt( s.LineProject( p ) ) },
                { "distSqP", s.SquaredDistance( p ) },
                { "distSqT", s.SquaredDistance( t ) },
                { "lineDist", s.LineDistance( p, true ) },
                { "intersect", opt( s.Intersect( t ) ) },
                { "intersectNoEnds", opt( s.Intersect( t, true ) ) },
                { "intersectLines", opt( s.IntersectLines( t ) ) },
                { "collide", collide },
                { "actual", collide ? actual : -1 },
                { "collinear", s.Collinear( t ) },
                { "overlaps", s.Overlaps( t ) },
                { "containsP", s.Contains( p ) },
                { "containsT", s.Contains( t ) },
                { "approxCollinear", s.ApproxCollinear( t ) },
                { "approxParallel", s.ApproxParallel( t ) },
        } );
    }

    out["segments"] = segs;

    // directions and the traces they start
    json dirs = json::array();

    for( int i = 0; i < n * 2; i++ )
    {
        VECTOR2I v = chance( 50 ) ? randFrom( VECTOR2I( 0, 0 ) ) : randPoint();
        VECTOR2I p0 = randPoint();
        VECTOR2I p1 = chance( 70 ) ? randFrom( p0 ) : randPoint();
        DIRECTION_45 d( v );
        bool diag = chance( 50 );
        bool ninety = chance( 25 );
        SHAPE_LINE_CHAIN trace = d.BuildInitialTrace( p0, p1, diag,
                                                      ninety ? DIRECTION_45::CORNER_MODE::MITERED_90
                                                             : DIRECTION_45::CORNER_MODE::MITERED_45 );
        DIRECTION_45 u;
        SHAPE_LINE_CHAIN traceU = u.BuildInitialTrace( p0, p1, diag );
        dirs.push_back( { { "v", pt( v ) }, { "dir", d.Format() },
                          { "p0", pt( p0 ) }, { "p1", pt( p1 ) }, { "diag", diag }, { "ninety", ninety },
                          { "trace", chainPoints( trace ) }, { "traceUndefined", chainPoints( traceU ) } } );
    }

    out["directions"] = dirs;

    // line chains
    json chains = json::array();

    for( int i = 0; i < n * 2; i++ )
    {
        bool closed = chance( 40 );
        SHAPE_LINE_CHAIN c = randChain( closed );
        SHAPE_LINE_CHAIN other = randChain( chance( 40 ) );

        if( chance( 40 ) )
        {
            // share points with the chain, to reach the corner cases
            for( int k = 0; k < other.PointCount(); k++ )
            {
                if( chance( 40 ) )
                    other.SetPoint( k, c.CPoint( uniform( 0, c.PointCount() - 1 ) ) );
            }

            // (closed again, its ends merged while they meet, as the chain read back from these points would be)
            while( other.IsClosed() && other.PointCount() > 1 && other.CPoint( 0 ) == other.CLastPoint() )
                other.SetClosed( true );
        }

        VECTOR2I p = chance( 30 ) ? c.CPoint( uniform( 0, c.PointCount() - 1 ) ) + VECTOR2I( uniform( -3, 3 ), uniform( -3, 3 ) )
                                  : randPoint();
        SEG s = chance( 50 ) ? relatedSeg( c.CSegment( uniform( 0, c.SegmentCount() - 1 ) ) ) : randSeg();
        int cl = uniform( 0, 500000 );
        int tol = chance( 50 ) ? 0 : uniform( 1, 50 );

        SHAPE_LINE_CHAIN simplified = c;
        simplified.Simplify( tol );
        SHAPE_LINE_CHAIN simplified2 = c;
        simplified2.Simplify2( true );
        SHAPE_LINE_CHAIN simplified2k = c;
        simplified2k.Simplify2( false );
        SHAPE_LINE_CHAIN split = c;
        int splitAt = split.Split( p );

        SHAPE_LINE_CHAIN::INTERSECTIONS ipsChain, ipsChainEx, ipsSeg;
        c.Intersect( other, ipsChain );
        c.Intersect( other, ipsChainEx, true );
        c.Intersect( s, ipsSeg );
        auto self = c.SelfIntersecting();

        int actualSeg = -1, actualP = -1;
        bool collideSeg = c.Collide( s, cl, &actualSeg );
        bool collideP = c.Collide( p, cl, &actualP );
        int nearDist = 0;
        VECTOR2I nearToSeg = c.NearestPoint( s, nearDist );
        int along = uniform( 0, std::max<int>( 1, c.Length() ) );

        json selfJ;

        if( self )
            selfJ = { { "p", pt( self->p ) }, { "our", self->index_our }, { "their", self->index_their } };

        chains.push_back( {
                { "points", chainPoints( c ) },
                { "closed", c.IsClosed() },
                { "other", chainPoints( other ) },
                { "otherClosed", other.IsClosed() },
                { "p", pt( p ) },
                { "s", json::array( { pt( s.A ), pt( s.B ) } ) },
                { "cl", cl },
                { "tol", tol },
                { "simplify", chainPoints( simplified ) },
                { "simplify2", chainPoints( simplified2 ) },
                { "simplify2KeepColinear", chainPoints( simplified2k ) },
                { "split", chainPoints( split ) },
                { "splitAt", splitAt },
                { "intersectChain", intersections( ipsChain ) },
                { "intersectChainExcluding", intersections( ipsChainEx ) },
                { "intersectSeg", intersections( ipsSeg ) },
                { "self", selfJ },
                { "inside", c.PointInside( p ) },
                { "insideAccuracy", c.PointInside( p, 3 ) },
                { "onEdge", c.PointOnEdge( p ) },
                { "nearest", pt( c.NearestPoint( p ) ) },
                { "nearestToSeg", pt( nearToSeg ) },
                { "nearestToSegDist", nearDist },
                { "pathLength", c.PathLength( p ) },
                { "length", c.Length() },
                { "along", along },
                { "pointAlong", pt( c.PointAlong( along ) ) },
                { "collideSeg", collideSeg },
                { "collideSegActual", collideSeg ? actualSeg : -1 },
                { "collideP", collideP },
                { "collidePActual", collideP ? actualP : -1 },
                { "area", c.Area() },
        } );
    }

    out["chains"] = chains;

    // shape collisions
    json collisions = json::array();

    for( int i = 0; i < n * 4; i++ )
    {
        std::unique_ptr<SHAPE> a( randShape( true ) );
        std::unique_ptr<SHAPE> b( nearShape( a.get(), true ) );
        int cl = chance( 10 ) ? 0 : uniform( 0, 600000 );
        int actual = -1;
        bool hit = a->Collide( b.get(), cl, &actual );
        bool hitBool = a->Collide( b.get(), cl );
        collisions.push_back( { { "a", shapeJSON( a.get() ) }, { "b", shapeJSON( b.get() ) }, { "cl", cl },
                                { "collide", hit }, { "collideNoActual", hitBool },
                                { "actual", hit ? actual : -1 } } );
    }

    out["collisions"] = collisions;

    // the router's hulls, and where paths cross them
    json hulls = json::array();

    for( int i = 0; i < n * 2; i++ )
    {
        std::unique_ptr<SHAPE> a( randShape( false ) );
        int cl = uniform( 0, 400000 );
        int thickness = chance( 10 ) ? 0 : uniform( 1, 600000 );
        SHAPE_LINE_CHAIN hull = PNS::BuildHullForPrimitiveShape( a.get(), cl, thickness );
        SHAPE_LINE_CHAIN line = randChain( false );

        if( chance( 60 ) )
        {
            // a path through the hull
            BOX2I bb = hull.BBox();
            line = SHAPE_LINE_CHAIN();
            line.Append( bb.GetOrigin() - VECTOR2I( uniform( 0, 500000 ), uniform( -500000, 500000 ) ) );

            if( chance( 50 ) )
                line.Append( bb.Centre() + VECTOR2I( uniform( -20000, 20000 ), uniform( -20000, 20000 ) ) );

            if( chance( 30 ) && hull.PointCount() > 0 )
                line.Append( hull.CPoint( uniform( 0, hull.PointCount() - 1 ) ) );

            line.Append( bb.GetEnd() + VECTOR2I( uniform( 0, 500000 ), uniform( -500000, 500000 ) ) );
        }

        SHAPE_LINE_CHAIN::INTERSECTIONS ips;
        PNS::HullIntersection( hull, line, ips );
        hulls.push_back( { { "shape", shapeJSON( a.get() ) }, { "cl", cl }, { "thickness", thickness },
                           { "hull", chainPoints( hull ) }, { "line", chainPoints( line ) },
                           { "crossings", intersections( ips ) } } );
    }

    out["hulls"] = hulls;

    // a path walked round a hull (LINE::Walkaround), both ways
    json walks = json::array();

    for( int i = 0; i < n * 2; i++ )
    {
        std::unique_ptr<SHAPE> a( randShape( false ) );
        int cl = uniform( 0, 400000 );
        int thickness = uniform( 1, 600000 );
        SHAPE_LINE_CHAIN hull = PNS::BuildHullForPrimitiveShape( a.get(), cl, thickness );
        BOX2I bb = hull.BBox();
        SHAPE_LINE_CHAIN path;
        VECTOR2I start = bb.GetOrigin() - VECTOR2I( uniform( 1, 800000 ), uniform( -800000, 1600000 ) );
        path.Append( start );

        if( chance( 40 ) )
            path.Append( start + VECTOR2I( uniform( 0, bb.GetWidth() ), 0 ) );

        if( chance( 30 ) && hull.PointCount() > 0 )
            path.Append( hull.CPoint( uniform( 0, hull.PointCount() - 1 ) ) );

        // the end beyond the hull, or inside it (as the pointer is when it is on an obstacle)
        VECTOR2I end = chance( 60 ) ? bb.GetEnd() + VECTOR2I( uniform( 1, 800000 ), uniform( -1600000, 800000 ) )
                                    : bb.Centre() + VECTOR2I( uniform( -bb.GetWidth() / 3, bb.GetWidth() / 3 ),
                                                              uniform( -bb.GetHeight() / 3, bb.GetHeight() / 3 ) );
        path.Append( end );

        PNS::LINE line;
        line.SetShape( path );
        line.SetWidth( thickness );
        json results = json::array();

        for( int cw = 0; cw < 2; cw++ )
        {
            SHAPE_LINE_CHAIN walked;
            bool ok = line.Walkaround( hull, walked, cw == 1 );
            results.push_back( { { "ok", ok }, { "path", ok ? chainPoints( walked ) : json::array() } } );
        }

        walks.push_back( { { "hull", chainPoints( hull ) }, { "path", chainPoints( path ) }, { "ccw", results[0] },
                           { "cw", results[1] } } );
    }

    out["walkarounds"] = walks;

    // arcs: how KiCad works them out, their polylines and hulls, points against them
    json arcs = json::array();

    for( int i = 0; i < n * 2; i++ )
    {
        SHAPE_ARC arc = randArc();
        int cl = chance( 10 ) ? 0 : uniform( 0, 600000 );
        int thickness = chance( 10 ) ? 0 : uniform( 1, 600000 );
        int maxError = chance( 50 ) ? 5000 : uniform( 1, 100000 );
        VECTOR2I p = chance( 50 ) ? arc.GetCenter() + VECTOR2I( uniform( -2000000, 2000000 ), uniform( -2000000, 2000000 ) )
                                  : randFrom( chance( 50 ) ? arc.GetP0() : arc.GetArcMid() );
        int actual = -1;
        VECTOR2I location;
        bool hit = arc.Collide( p, cl, &actual, &location );
        BOX2I bb = arc.BBox( cl );
        json j = { { "arc", shapeJSON( &arc ) }, { "cl", cl }, { "thickness", thickness }, { "maxError", maxError },
                   { "p", pt( p ) }, { "center", pt( arc.GetCenter() ) }, { "radius", arc.GetRadius() },
                   { "bbox", json::array( { pt( bb.GetOrigin() ), pt( bb.GetEnd() ) } ) },
                   { "startAngle", arc.GetStartAngle().AsDegrees() }, { "endAngle", arc.GetEndAngle().AsDegrees() },
                   { "centralAngle", arc.GetCentralAngle().AsDegrees() }, { "ccw", arc.IsCCW() },
                   { "effectiveLine", arc.IsEffectiveLine() }, { "collide", hit }, { "actual", hit ? actual : -1 },
                   { "nearest", pt( arc.NearestPoint( p ) ) } };

        j["polyline"] = chainPoints( arc.ConvertToPolyline( maxError ) );
        j["hull"] = chainPoints( PNS::BuildHullForPrimitiveShape( &arc, cl, thickness ) );

        arcs.push_back( j );
    }

    out["arcs"] = arcs;

    // arcs against every shape, and each other, either way round, asked how close or not
    json arcCollisions = json::array();

    for( int i = 0; i < n * 4; i++ )
    {
        SHAPE_ARC arc = randArc();
        std::unique_ptr<SHAPE> b;

        if( chance( 20 ) )
        {
            b.reset( new SHAPE_ARC( randArc() ) );
        }
        else
        {
            b.reset( randShape( true ) );
        }

        if( chance( 70 ) )
        {
            VECTOR2I to = arc.Centre() + VECTOR2I( uniform( -1500000, 1500000 ), uniform( -1500000, 1500000 ) );
            b->Move( to - b->Centre() );
        }

        int cl = chance( 10 ) ? 0 : uniform( 0, 600000 );
        int actual = -1, actualR = -1;
        bool hit = arc.Collide( b.get(), cl, &actual );
        bool hitBool = arc.Collide( b.get(), cl );
        bool hitR = b->Collide( &arc, cl, &actualR );
        bool hitRBool = b->Collide( &arc, cl );
        json j = { { "a", shapeJSON( &arc ) }, { "b", shapeJSON( b.get() ) }, { "cl", cl }, { "collide", hit },
                   { "collideNoActual", hitBool }, { "actual", hit ? actual : -1 }, { "collideReversed", hitR },
                   { "collideReversedNoActual", hitRBool }, { "actualReversed", hitR ? actualR : -1 } };

        // how far a via must move to clear the arc
        if( b->Type() == SH_CIRCLE )
        {
            VECTOR2I mtv;
            bool hitMTV = static_cast<const SHAPE&>( arc ).Collide( b.get(), cl, &mtv );
            j["mtv"] = hitMTV ? pt( mtv ) : json();
        }

        arcCollisions.push_back( j );
    }

    out["arcCollisions"] = arcCollisions;

    // pads' shapes as polygons: rectangles with rounded or cut corners, trapezoids, circles; turned, grown or shrunk
    json padPolygons = json::array();

    for( int i = 0; i < n * 2; i++ )
    {
        VECTOR2I pos = randPoint();
        int sx = chance( 10 ) ? uniform( 2, 50 ) : uniform( 100, 3000000 );
        int sy = chance( 20 ) ? sx : chance( 10 ) ? uniform( 2, 50 ) : uniform( 100, 3000000 );
        VECTOR2I size( sx, sy );
        EDA_ANGLE rot = chance( 40 ) ? ANGLE_0 : chance( 50 ) ? EDA_ANGLE( uniform( 0, 7 ) * 45.0, DEGREES_T )
                                                            : EDA_ANGLE( std::uniform_real_distribution<double>( 0, 360 )( rng ), DEGREES_T );
        int inflate = chance( 50 ) ? 0 : chance( 60 ) ? uniform( 1, 300000 ) : -uniform( 1, std::min( sx, sy ) );
        int maxError = chance( 50 ) ? 5000 : uniform( 1, 50000 );
        bool outside = chance( 50 );
        ERROR_LOC loc = outside ? ERROR_OUTSIDE : ERROR_INSIDE;
        SHAPE_POLY_SET poly;
        json j = { { "pos", pt( pos ) }, { "size", pt( size ) }, { "rotation", rot.AsDegrees() }, { "inflate", inflate },
                   { "maxError", maxError }, { "outside", outside } };

        switch( uniform( 0, 2 ) )
        {
        case 0:
        {
            double ratio = chance( 20 ) ? 0.5 : std::uniform_real_distribution<double>( 0, 0.5 )( rng );
            int radius = chance( 10 ) ? 0 : KiROUND( std::min( sx, sy ) * ratio );
            int corners = chance( 50 ) ? 0 : uniform( 0, 15 );
            double chamfer = chance( 20 ) ? 0.5 : std::uniform_real_distribution<double>( 0, 0.5 )( rng );
            TransformRoundChamferedRectToPolygon( poly, pos, size, rot, radius, chamfer, corners, inflate, maxError, loc );
            j["kind"] = "roundrect";
            j["radius"] = radius;
            j["chamferRatio"] = chamfer;
            j["chamferCorners"] = corners;
            break;
        }
        case 1:
        {
            int dx = 0, dy = 0;

            if( chance( 50 ) )
                dx = uniform( -sy / 2, sy / 2 );
            else
                dy = uniform( -sx / 2, sx / 2 );

            TransformTrapezoidToPolygon( poly, pos, size, rot, dx, dy, inflate, maxError, loc );
            j["kind"] = "trapezoid";
            j["dx"] = dx;
            j["dy"] = dy;
            break;
        }
        default:
        {
            int minSegs = chance( 50 ) ? 16 : 0;
            TransformCircleToPolygon( poly, pos, sx, maxError, loc, minSegs );
            j["kind"] = "circle";
            j["minSegs"] = minSegs;
            break;
        }
        }

        j["outline"] = poly.OutlineCount() ? chainPoints( poly.Outline( 0 ) ) : json::array();
        padPolygons.push_back( j );
    }

    out["padPolygons"] = padPolygons;

    // triangulations: polygons cut into triangles as KiCad cuts zones and keepouts (POLYGON_TRIANGULATION):
    // star-shaped and convex outlines, rectilinear ones like keepouts, ones with points nearer than its
    // simplification level or in line, outlines with a hole fractured into them, and chains that cross themselves
    json triangulations = json::array();

    for( int i = 0; i < n; i++ )
    {
        SHAPE_LINE_CHAIN poly;
        VECTOR2I c = randPoint();
        int kind = uniform( 0, 5 );

        switch( kind )
        {
        case 0: // star-shaped: points round a centre at angles in order, distances at random
        {
            int k = uniform( 3, 24 );
            std::vector<double> angles;

            for( int j = 0; j < k; j++ )
                angles.push_back( std::uniform_real_distribution<double>( 0, 2 * M_PI )( rng ) );

            std::sort( angles.begin(), angles.end() );

            for( double a : angles )
            {
                int r = chance( 10 ) ? uniform( 1, 100 ) : uniform( 100000, 5000000 );
                poly.Append( c + VECTOR2I( KiROUND( r * cos( a ) ), KiROUND( r * sin( a ) ) ) );
            }

            break;
        }
        case 1: // convex
        {
            SHAPE_SIMPLE s = randConvex();

            for( int j = 0; j < s.PointCount(); j++ )
                poly.Append( s.CPoint( j ) );

            break;
        }
        case 2: // rectilinear: a staircase, an L, a U
        {
            int w = uniform( 500000, 8000000 ), h = uniform( 500000, 8000000 );
            int steps = uniform( 1, 4 );
            poly.Append( c );
            poly.Append( c + VECTOR2I( w, 0 ) );

            for( int j = 1; j <= steps; j++ )
            {
                poly.Append( c + VECTOR2I( w - ( j - 1 ) * w / ( steps + 1 ), j * h / steps ) );
                poly.Append( c + VECTOR2I( w - j * w / ( steps + 1 ), j * h / steps ) );
            }

            poly.Append( c + VECTOR2I( 0, h ) );

            if( chance( 50 ) ) // a notch in the left side
            {
                poly.Append( c + VECTOR2I( 0, h * 2 / 3 ) );
                poly.Append( c + VECTOR2I( w / 3, h * 2 / 3 ) );
                poly.Append( c + VECTOR2I( w / 3, h / 3 ) );
                poly.Append( c + VECTOR2I( 0, h / 3 ) );
            }

            break;
        }
        case 3: // points crowded and in line
        {
            int k = uniform( 4, 16 );
            std::vector<double> angles;

            for( int j = 0; j < k; j++ )
                angles.push_back( std::uniform_real_distribution<double>( 0, 2 * M_PI )( rng ) );

            std::sort( angles.begin(), angles.end() );

            for( double a : angles )
            {
                int r = uniform( 1000000, 3000000 );
                VECTOR2I p = c + VECTOR2I( KiROUND( r * cos( a ) ), KiROUND( r * sin( a ) ) );
                poly.Append( p );

                if( chance( 30 ) )
                    poly.Append( p + VECTOR2I( uniform( -60, 60 ), uniform( -60, 60 ) ) );

                if( chance( 20 ) && poly.PointCount() >= 2 )
                {
                    VECTOR2I a2 = poly.CPoint( -2 );
                    poly.Insert( poly.PointCount() - 1, ( a2 + p ) / 2 );
                }
            }

            break;
        }
        case 4: // an outline with a hole, fractured into one
        {
            SHAPE_POLY_SET set;
            int w = uniform( 2000000, 9000000 ), h = uniform( 2000000, 9000000 );
            SHAPE_LINE_CHAIN outer( { c, c + VECTOR2I( w, 0 ), c + VECTOR2I( w, h ), c + VECTOR2I( 0, h ) } );
            outer.SetClosed( true );
            set.AddOutline( outer );
            VECTOR2I hc = c + VECTOR2I( uniform( w / 4, w * 3 / 4 ), uniform( h / 4, h * 3 / 4 ) );
            int hr = uniform( 200000, std::min( w, h ) / 5 );
            SHAPE_LINE_CHAIN hole( { hc + VECTOR2I( -hr, -hr ), hc + VECTOR2I( hr, -hr ), hc + VECTOR2I( hr, hr ),
                                     hc + VECTOR2I( -hr, hr ) } );
            hole.SetClosed( true );
            set.AddHole( hole );
            set.Fracture();
            poly = set.Outline( 0 );
            break;
        }
        default: // a chain that may cross itself
            poly = randChain( true );
            break;
        }

        poly.SetClosed( true );

        if( chance( 50 ) ) // either way round
        {
            SHAPE_LINE_CHAIN r = poly.Reverse();
            r.SetClosed( true );
            poly = r;
        }

        SHAPE_POLY_SET::TRIANGULATED_POLYGON tri( -1 );
        POLYGON_TRIANGULATION tess( tri );
        bool ok = tess.TesselatePolygon( poly, nullptr );
        json tris = json::array();

        for( const SHAPE_POLY_SET::TRIANGULATED_POLYGON::TRI& t : tri.Triangles() )
            tris.push_back( json::array( { t.a, t.b, t.c } ) );

        json verts = json::array();

        for( const VECTOR2I& v : tri.Vertices() )
            verts.push_back( pt( v ) );

        triangulations.push_back( { { "kind", kind }, { "poly", chainPoints( poly ) }, { "ok", ok }, { "vertices", verts },
                                    { "triangles", tris } } );
    }

    out["triangulations"] = triangulations;

    // polygon sets cut into triangles as KiCad cuts a keepout zone's outline for its router (SHAPE_POLY_SET::
    // CacheTriangulation( false )), with what Simplify and Fracture make of them and the fractured outlines split where
    // they touch themselves: outlines with holes in them, across them and over each other, holes touching the outline
    // and each other on small grids, outlines that touch or cross themselves, points in line or repeated, spikes,
    // waists of no width, several outlines and islands in holes, many points, points crowded within the
    // triangulation's 50 nm, outlines like real keepouts', degenerate ones; on grids of a nanometre to ten millimetres
    json polySets = json::array();

    for( int i = 0; i < n; i++ )
    {
        int kind = uniform( 0, 9 );
        int g = chance( 8 ) ? uniform( 1, 4 )
                : chance( 8 ) ? uniform( 5000000, 10000000 )
                : chance( 40 ) ? 10000 * uniform( 1, 40 ) : uniform( 100, 300000 );
        VECTOR2I c = randPoint();

        if( g >= 5000000 )
        {
            int cx = uniform( -40, 40 ) * 10000000;
            int cy = uniform( -40, 40 ) * 10000000;
            c = VECTOR2I( cx, cy );
        }

        auto G = [&]( int x, int y ) { return c + VECTOR2I( x * g, y * g ); };
        SHAPE_POLY_SET set;
        json polys = json::array();

        // an outline, or a hole in the last outline, point by point as KiCad builds one (SHAPE_POLY_SET::Append)
        auto add = [&]( const std::vector<VECTOR2I>& aPoints, bool aHole )
        {
            aHole = aHole && set.OutlineCount() > 0;

            if( aHole )
            {
                set.NewHole();
            }
            else
            {
                set.NewOutline();
                polys.push_back( json::array() );
            }

            json chain = json::array();

            for( const VECTOR2I& p : aPoints )
            {
                set.Append( p.x, p.y, -1, aHole ? set.HoleCount( set.OutlineCount() - 1 ) - 1 : -1 );
                chain.push_back( pt( p ) );
            }

            polys.back().push_back( chain );
        };

        auto randomHole = [&]( int aW, int aH )
        {
            int hx = uniform( -1, aW ), hy = uniform( -1, aH );
            int hw = uniform( 1, std::max( 1, aW / 3 ) ), hh = uniform( 1, std::max( 1, aH / 3 ) );
            add( turned( boxPoints( G( hx, hy ), G( hx + hw, hy + hh ) ) ), true );
        };

        switch( kind )
        {
        case 0: // an outline with holes at random: in it, across its edge, over each other
        {
            int w = uniform( 6, 40 ), h = uniform( 6, 40 );

            if( chance( 60 ) )
            {
                add( turned( boxPoints( G( 0, 0 ), G( w, h ) ) ), false );
            }
            else
            {
                int  k = uniform( 3, 24 );
                bool star = chance( 40 );
                bool even = chance( 50 );
                add( turned( roundPoints( G( w / 2, h / 2 ), std::max( 1, std::min( w, h ) / 2 * g ), k, star, even ) ),
                     false );
            }

            for( int k = uniform( 1, 5 ); k > 0; k-- )
            {
                if( chance( 70 ) )
                {
                    randomHole( w, h );
                }
                else
                {
                    int hx = uniform( 0, w ), hy = uniform( 0, h ), hr = uniform( 1, std::max( 1, std::min( w, h ) / 4 ) );
                    int m = uniform( 3, 12 );
                    bool star = chance( 30 );
                    add( turned( roundPoints( G( hx, hy ), hr * g, m, star, true ) ), true );
                }
            }

            break;
        }
        case 1: // on a small grid: holes sharing edges and corners with the outline and each other
        {
            int m = uniform( 3, 8 );
            int shape = uniform( 0, 2 );

            if( shape == 0 )
                add( turned( boxPoints( G( 0, 0 ), G( m, m ) ) ), false );
            else if( shape == 1 ) // an L
                add( turned( { G( 0, 0 ), G( m, 0 ), G( m, m / 2 ), G( m / 2, m / 2 ), G( m / 2, m ), G( 0, m ) } ), false );
            else // a U
                add( turned( { G( 0, 0 ), G( m, 0 ), G( m, m ), G( m - 1, m ), G( m - 1, 1 ), G( 1, 1 ), G( 1, m ), G( 0, m ) } ),
                     false );

            for( int k = uniform( 1, 6 ); k > 0; k-- )
            {
                int x0 = uniform( 0, m - 1 ), y0 = uniform( 0, m - 1 );
                int x1 = std::min( m, x0 + uniform( 1, 3 ) ), y1 = std::min( m, y0 + uniform( 1, 3 ) );

                if( chance( 80 ) )
                    add( turned( boxPoints( G( x0, y0 ), G( x1, y1 ) ) ), true );
                else
                    add( turned( { G( x0, y0 ), G( x1, y0 ), G( x0, y1 ) } ), true );
            }

            break;
        }
        case 2: // an outline that touches itself: a notch whose tip is on its far edge (with more than 32 points now and
                // then), two boxes meeting at a corner, a hole touching it at a point
        {
            int w = uniform( 4, 14 ), h = uniform( 4, 14 );
            int variant = uniform( 0, 3 );

            if( variant == 0 )
            {
                int tx = uniform( 0, w );
                int x1 = std::min( w, tx + uniform( 1, 3 ) ), x2 = std::max( 0, tx - uniform( 1, 3 ) );
                add( turned( { G( 0, 0 ), G( w, 0 ), G( w, h ), G( x1, h ), G( tx, 0 ), G( x2, h ), G( 0, h ) } ), false );
            }
            else if( variant == 1 )
            {
                int w2 = uniform( 2, 10 ), h2 = uniform( 2, 10 );
                add( turned( { G( 0, 0 ), G( w, 0 ), G( w, h ), G( w + w2, h ), G( w + w2, h + h2 ), G( w, h + h2 ), G( w, h ),
                               G( 0, h ) } ),
                     false );
            }
            else if( variant == 2 )
            {
                add( turned( boxPoints( G( 0, 0 ), G( w, h ) ) ), false );
                int hx = uniform( 1, w - 2 ), hy = uniform( 1, h - 2 );
                add( turned( { G( hx, 0 ), G( hx + 1, hy ), G( hx, hy + 1 ), G( hx - 1, hy ) } ), true );

                if( chance( 50 ) )
                    add( turned( boxPoints( G( hx + 1, hy ), G( w, hy + 1 ) ) ), true );
            }
            else
            {
                // round, a notch from one side to a point on the edge across (rounded onto it, or nearly)
                int k = 2 * uniform( 4, 24 );
                std::vector<VECTOR2I> round = roundPoints( G( w, w ), std::max( 1, w * g ), k, false, true ), pts;
                VECTOR2I tip = ( round[0] + round[1] ) / 2;

                for( int j = 0; j < k; j++ )
                {
                    pts.push_back( round[j] );

                    if( j == k / 2 )
                        pts.push_back( tip );
                }

                add( turned( pts ), false );
            }

            if( chance( 30 ) )
                randomHole( w, h );

            break;
        }
        case 3: // an outline that crosses itself: a bow tie, a star, a chain at random
        {
            int w = uniform( 2, 20 ), h = uniform( 2, 20 );
            int shape = uniform( 0, 2 );

            if( shape == 0 )
            {
                add( turned( { G( 0, 0 ), G( w, h ), G( w, 0 ), G( 0, h ) } ), false );
            }
            else if( shape == 1 )
            {
                int k = 2 * uniform( 2, 4 ) + 1;
                std::vector<VECTOR2I> round = roundPoints( G( w, w ), std::max( 1, w * g ), k, false, true ), star;

                for( int j = 0; j < k; j++ )
                    star.push_back( round[( 2 * j ) % k] );

                add( turned( star ), false );
            }
            else
            {
                add( turned( randChain( true ).CPoints() ), false );
            }

            if( chance( 40 ) )
                randomHole( w, h );

            break;
        }
        case 4: // points in line and repeated, spikes out and back, and two boxes joined by a waist of no width (out
                // along a line and back along it, broken at another point, or a few nanometres off it)
        {
            int w = uniform( 2, 10 ), h = uniform( 2, 10 );
            std::vector<VECTOR2I> pts;

            if( chance( 50 ) )
            {
                std::vector<VECTOR2I> box = boxPoints( G( 0, 0 ), G( w, h ) );

                for( int j = 0; j < 4; j++ )
                {
                    VECTOR2I a = box[j], b = box[( j + 1 ) % 4];
                    pts.push_back( a );

                    if( chance( 30 ) )
                        pts.push_back( a );

                    int pieces = uniform( 0, 3 );

                    for( int s = 1; s <= pieces; s++ )
                        pts.push_back( a + ( b - a ) * s / ( pieces + 1 ) );

                    if( chance( 30 ) )
                    {
                        VECTOR2I m = ( a + b ) / 2;
                        VECTOR2I d = ( b - a ).Perpendicular().Resize( uniform( 1, 3 ) * g );
                        bool     out = chance( 50 );
                        pts.push_back( m );
                        pts.push_back( out ? m + d : m - d );
                        pts.push_back( m );
                    }
                }
            }
            else
            {
                int l = uniform( 1, 6 ), w2 = uniform( 1, 6 );
                int y = uniform( 0, h );
                int off = chance( 50 ) ? 0 : uniform( -12, 12 );
                pts = { G( 0, 0 ), G( w, 0 ), G( w, y ), G( w + l, y ), G( w + l, 0 ), G( w + l + w2, 0 ), G( w + l + w2, h ),
                        G( w + l, h ), G( w + l, y ) + VECTOR2I( 0, off ) };

                if( off == 0 && l > 1 )
                    pts.push_back( G( w + uniform( 1, l - 1 ), y ) );

                pts.push_back( G( w, y ) + VECTOR2I( 0, off ) );
                pts.push_back( G( w, h ) );
                pts.push_back( G( 0, h ) );
            }

            add( turned( pts ), false );

            if( chance( 30 ) )
                randomHole( w, h );

            break;
        }
        case 5: // several outlines, apart, over each other or touching, some with holes; an island in a hole
        {
            for( int k = uniform( 2, 4 ); k > 0; k-- )
            {
                int x = uniform( 0, 20 ), y = uniform( 0, 20 ), w = uniform( 2, 10 ), h = uniform( 2, 10 );
                add( turned( boxPoints( G( x, y ), G( x + w, y + h ) ) ), false );

                if( w > 2 && h > 2 && chance( 40 ) )
                    add( turned( boxPoints( G( x + 1, y + 1 ), G( x + w - 1, y + h - 1 ) ) ), true );
            }

            if( chance( 50 ) )
            {
                add( turned( boxPoints( G( 30, 0 ), G( 40, 10 ) ) ), false );
                add( turned( boxPoints( G( 31, 1 ), G( 39, 9 ) ) ), true );
                add( turned( boxPoints( G( 33, 3 ), G( 37, 7 ) ) ), false );

                if( chance( 50 ) )
                    add( turned( boxPoints( G( 34, 4 ), G( 36, 6 ) ) ), true );
            }

            break;
        }
        case 6: // many points: a round outline with round holes, which may touch it or each other
        {
            int r = uniform( 10, 40 ) * g;
            int k = uniform( 32, 96 );
            bool star = chance( 20 );
            add( turned( roundPoints( c, r, k, star, true ) ), false );

            for( int m = uniform( 0, 4 ); m > 0; m-- )
            {
                double a = std::uniform_real_distribution<double>( 0, 2 * M_PI )( rng );
                double d = r * ( uniform( 0, 100 ) / 100.0 );
                int    hr = std::max( 1, r / 100 * uniform( 2, 30 ) );
                int    hk = uniform( 8, 40 );
                add( turned( roundPoints( c + VECTOR2I( KiROUND( d * cos( a ) ), KiROUND( d * sin( a ) ) ), hr, hk, false,
                                          true ) ),
                     true );
            }

            break;
        }
        case 7: // crowded: points within the triangulation's 50 nm of others, spikes of a few nanometres; holes a few
                // nanometres from the outline's edge, and near copies of holes (their fracture one KiCad's
                // triangulation may not cut, then cut once simplified, or not at all)
        {
            int variant = uniform( 0, 2 );

            if( variant == 1 )
            {
                int s = uniform( 1000, 200000 );
                add( turned( boxPoints( c, c + VECTOR2I( 10 * s, 10 * s ) ) ), false );

                for( int k = uniform( 1, 4 ); k > 0; k-- )
                {
                    int gap = uniform( 1, 80 );
                    int w = uniform( 1, 4 ) * s, h = uniform( 1, 4 ) * s;
                    int x = chance( 50 ) ? gap : uniform( 1, 5 ) * s;
                    int y = uniform( 1, 5 ) * s;
                    y += uniform( -80, 80 );
                    add( turned( boxPoints( c + VECTOR2I( x, y ), c + VECTOR2I( x + w, y + h ) ) ), true );
                }

                break;
            }
            else if( variant == 2 )
            {
                int s = uniform( 1000, 200000 );
                int d = uniform( 5, 60 );
                add( turned( boxPoints( c, c + VECTOR2I( 10 * s, 10 * s ) ) ), false );

                for( int k = uniform( 1, 3 ); k > 0; k-- )
                {
                    int x = uniform( 0, 6 ) * s, y = uniform( 0, 6 ) * s;
                    int w = uniform( 1, 4 ) * s, h = uniform( 1, 4 ) * s;

                    for( int m = uniform( 2, 4 ); m > 0; m-- )
                    {
                        VECTOR2I o = c + VECTOR2I( x, y ) + jitter( d );
                        add( turned( boxPoints( o, o + VECTOR2I( w, h ) ) ), true );
                    }
                }

                break;
            }

            int k = uniform( 4, 16 );
            int r = uniform( 1000, 3000000 );
            bool star = chance( 50 );
            bool even = chance( 30 );
            std::vector<VECTOR2I> pts;

            for( const VECTOR2I& p : roundPoints( c, r, k, star, even ) )
            {
                pts.push_back( p );

                if( chance( 40 ) )
                    pts.push_back( p + jitter( 60 ) );

                if( chance( 15 ) )
                {
                    pts.push_back( p + jitter( 30 ) );
                    pts.push_back( p );
                }
            }

            add( turned( pts ), false );

            if( chance( 50 ) )
            {
                std::vector<VECTOR2I> hole;

                for( const VECTOR2I& p : roundPoints( c, std::max( 1, r / 4 ), uniform( 3, 8 ), false, false ) )
                {
                    hole.push_back( p );

                    if( chance( 40 ) )
                        hole.push_back( p + jitter( 60 ) );
                }

                add( turned( hole ), true );
            }

            break;
        }
        case 8: // as keepouts are drawn: boxes, L shapes and polygons of a few millimetres on a 0.01 mm grid, with
                // round holes for mounting holes and box ones
        {
            g = 10000;
            int cx = uniform( 0, 20000 ), cy = uniform( 0, 20000 );
            c = VECTOR2I( cx * g, cy * g );
            int w = uniform( 100, 2000 ), h = uniform( 100, 2000 );
            int shape = uniform( 0, 2 );

            if( shape == 0 )
            {
                add( turned( boxPoints( G( 0, 0 ), G( w, h ) ) ), false );
            }
            else if( shape == 1 )
            {
                int a = uniform( 20, w - 20 ), b = uniform( 20, h - 20 );
                add( turned( { G( 0, 0 ), G( w, 0 ), G( w, b ), G( a, b ), G( a, h ), G( 0, h ) } ), false );
            }
            else
            {
                int  k = uniform( 5, 10 );
                bool star = chance( 50 );
                add( turned( roundPoints( G( w / 2, h / 2 ), std::min( w, h ) / 2 * g, k, star, false ) ), false );
            }

            for( int m = uniform( 0, 3 ); m > 0; m-- )
            {
                int hx = uniform( 0, w ), hy = uniform( 0, h );

                if( chance( 60 ) )
                {
                    int hr = uniform( 50, 300 ), hk = 4 * uniform( 4, 16 );
                    add( turned( roundPoints( G( hx, hy ), hr * g, hk, false, true ) ), true );
                }
                else
                {
                    int hw = uniform( 20, 400 ), hh = uniform( 20, 400 );
                    add( turned( boxPoints( G( hx, hy ), G( hx + hw, hy + hh ) ) ), true );
                }
            }

            break;
        }
        default: // degenerate: an outline already fractured (out to a hole along a bridge, round it and back), all in
                 // line, of one or two points, with an empty hole
        {
            int w = uniform( 4, 20 ), h = uniform( 4, 20 );
            int variant = uniform( 0, 3 );

            if( variant == 0 )
            {
                int hx = uniform( 1, w - 3 ), hy = uniform( 1, h - 3 );
                add( turned( { G( 0, 0 ), G( w, 0 ), G( w, h ), G( 0, h ), G( 0, hy ), G( hx, hy ), G( hx, hy + 2 ),
                               G( hx + 2, hy + 2 ), G( hx + 2, hy ), G( hx, hy ), G( 0, hy ) } ),
                     false );
            }
            else if( variant == 1 )
            {
                add( turned( { G( 0, 0 ), G( w, 0 ), G( 2 * w, 0 ), G( w, 0 ) } ), false );
            }
            else if( variant == 2 )
            {
                add( chance( 50 ) ? std::vector<VECTOR2I>{ G( 0, 0 ) } : std::vector<VECTOR2I>{ G( 0, 0 ), G( w, h ) }, false );

                if( chance( 50 ) )
                    add( turned( boxPoints( G( 0, 0 ), G( w, h ) ) ), false );
            }
            else
            {
                add( turned( boxPoints( G( 0, 0 ), G( w, h ) ) ), false );
                add( {}, true );
                add( { G( 1, 1 ), G( 2, 2 ) }, true );
            }

            break;
        }
        }

        polySets.push_back( polySetCase( kind, polys, set ) );
    }

    // and inputs found by searching for ones that take the triangulation its rarer ways: near copies of holes whose
    // fractured outline KiCad cannot cut, then can once simplified, or still cannot; and two of those together (once
    // one has been simplified and tried again, the next that cannot be cut is not)
    using POLYS = std::vector<std::vector<std::vector<VECTOR2I>>>;
    const POLYS cutOnceSimplified = {
        { { { 0, 0 }, { 24720, 0 }, { 24720, 24720 }, { 0, 24720 } },
          { { 14834, 7444 }, { 24722, 7444 }, { 24722, 14860 }, { 14834, 14860 } },
          { { 14819, 7422 }, { 24707, 7422 }, { 24707, 14838 }, { 14819, 14838 } },
          { { 14847, 7398 }, { 24735, 7398 }, { 24735, 14814 }, { 14847, 14814 } },
          { { 14856, 7417 }, { 24744, 7417 }, { 24744, 14833 }, { 14856, 14833 } },
          { { 7428, 9901 }, { 12372, 9901 }, { 12372, 14845 }, { 7428, 14845 } },
          { { 7400, 9870 }, { 12344, 9870 }, { 12344, 14814 }, { 7400, 14814 } },
          { { 4937, 20 }, { 7409, 20 }, { 7409, 4964 }, { 4937, 4964 } },
          { { 4940, 8 }, { 7412, 8 }, { 7412, 4952 }, { 4940, 4952 } } } };
    const POLYS cutOnceSimplified2 = {
        { { { 0, 0 }, { 8090, 0 }, { 8090, 8090 }, { 0, 8090 } },
          { { 3250, 769 }, { 4868, 769 }, { 4868, 4005 }, { 3250, 4005 } },
          { { 3248, 825 }, { 4866, 825 }, { 4866, 4061 }, { 3248, 4061 } },
          { { 3195, 770 }, { 4813, 770 }, { 4813, 4006 }, { 3195, 4006 } },
          { { 1613, 834 }, { 2422, 834 }, { 2422, 2452 }, { 1613, 2452 } },
          { { 1611, 776 }, { 2420, 776 }, { 2420, 2394 }, { 1611, 2394 } },
          { { 1608, 815 }, { 2417, 815 }, { 2417, 2433 }, { 1608, 2433 } },
          { { 1609, 785 }, { 2418, 785 }, { 2418, 2403 }, { 1609, 2403 } } } };
    const POLYS notCut = {
        { { { 0, 0 }, { 7300, 0 }, { 7300, 7300 }, { 0, 7300 } },
          { { 2909, 4391 }, { 4369, 4391 }, { 4369, 7311 }, { 2909, 7311 } },
          { { 2926, 4368 }, { 4386, 4368 }, { 4386, 7288 }, { 2926, 7288 } },
          { { 2923, 4370 }, { 4383, 4370 }, { 4383, 7290 }, { 2923, 7290 } },
          { { 725, 3649 }, { 1455, 3649 }, { 1455, 6569 }, { 725, 6569 } },
          { { 742, 3641 }, { 1472, 3641 }, { 1472, 6561 }, { 742, 6561 } },
          { { 2913, 2910 }, { 5833, 2910 }, { 5833, 3640 }, { 2913, 3640 } },
          { { 2923, 2925 }, { 5843, 2925 }, { 5843, 3655 }, { 2923, 3655 } } } };
    const POLYS notCut2 = {
        { { { 0, 0 }, { 21640, 0 }, { 21640, 21640 }, { 0, 21640 } },
          { { -2, 8701 }, { 2162, 8701 }, { 2162, 10865 }, { -2, 10865 } },
          { { 46, 8612 }, { 2210, 8612 }, { 2210, 10776 }, { 46, 10776 } },
          { { 100, 6519 }, { 2264, 6519 }, { 2264, 8683 }, { 100, 8683 } },
          { { 63, 6486 }, { 2227, 6486 }, { 2227, 8650 }, { 63, 8650 } },
          { { 79, 2121 }, { 6571, 2121 }, { 6571, 6449 }, { 79, 6449 } },
          { { 85, 2203 }, { 6577, 2203 }, { 6577, 6531 }, { 85, 6531 } },
          { { 10, 2141 }, { 6502, 2141 }, { 6502, 6469 }, { 10, 6469 } },
          { { 71, 2120 }, { 6563, 2120 }, { 6563, 6448 }, { 71, 6448 } } } };

    // (a polygon set of these, the second moved off to the right of the first)
    auto together = []( const POLYS& a, const POLYS& b )
    {
        POLYS both = a;

        for( std::vector<std::vector<VECTOR2I>> polygon : b )
        {
            for( std::vector<VECTOR2I>& chain : polygon )
            {
                for( VECTOR2I& p : chain )
                    p += VECTOR2I( 100000, 0 );
            }

            both.push_back( polygon );
        }

        return both;
    };

    for( const POLYS& found : { cutOnceSimplified, cutOnceSimplified2, notCut, notCut2,
                                together( cutOnceSimplified, cutOnceSimplified2 ), together( cutOnceSimplified, notCut ),
                                together( notCut2, cutOnceSimplified2 ) } )
    {
        SHAPE_POLY_SET set;
        json polys = json::array();

        for( const std::vector<std::vector<VECTOR2I>>& polygon : found )
        {
            json chains = json::array();

            for( size_t h = 0; h < polygon.size(); h++ )
            {
                h == 0 ? set.NewOutline() : set.NewHole();
                json chain = json::array();

                for( const VECTOR2I& p : polygon[h] )
                {
                    set.Append( p.x, p.y, -1, h == 0 ? -1 : (int) h - 1 );
                    chain.push_back( pt( p ) );
                }

                chains.push_back( chain );
            }

            polys.push_back( chains );
        }

        polySets.push_back( polySetCase( 10, polys, set ) );
    }

    out["polySets"] = polySets;

    std::cout << out.dump() << std::endl;
    return 0;
}
