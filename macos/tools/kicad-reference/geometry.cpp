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

#include <cstdio>
#include <iostream>
#include <random>

using json = nlohmann::json;

static std::mt19937_64 rng( 20261016 );

static int uniform( int lo, int hi ) { return std::uniform_int_distribution<int>( lo, hi )( rng ); }
static bool chance( int percent ) { return uniform( 0, 99 ) < percent; }

static json pt( const VECTOR2I& p ) { return json::array( { p.x, p.y } ); }
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

int main( int argc, char** argv )
{
    int n = argc > 1 ? atoi( argv[1] ) : 400;
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

    std::cout << out.dump() << std::endl;
    return 0;
}
