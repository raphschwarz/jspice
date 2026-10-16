// The polygon clipper KiCad 10.0.7 ships (thirdparty/clipper2, Clipper2 by Angus Johnson) on random cases, written as
// JSON for KiCadRouterTests: boolean operations (union, intersection, difference, xor, with every fill rule, open
// subject paths, collinear points kept or not, solutions reversed or not) and offsets (every join and end type,
// growing and shrinking, miter limits and arc tolerances), each as paths and as a tree of outlines and holes, with
// the z values KiCad uses to follow arcs through them; the helpers (areas, point in polygon, simplification); and
// the order std::sort leaves equal points in (Clipper2 sorts each scanbeam's crossings with it). Each case has its
// input and what Clipper2 made of it, so that the Swift port can be checked against it point for point; each runs in
// a child process, as Clipper2 recurses for ever on a few inputs (those cases are kept, marked as crashed). build.sh
// builds this against KiCad's sources, compiled as KiCad compiles them (USINGZ: points carry a z value).
//
// This program links KiCad's code: GNU General Public License version 3 or later, as KiCad (Clipper2 itself is under
// the Boost Software License 1.0).

#include <clipper2/clipper.h>
#include <nlohmann/json.hpp>

#include <cmath>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <optional>
#include <random>
#include <sys/wait.h>
#include <unistd.h>

using json = nlohmann::json;
using namespace Clipper2Lib;

static std::mt19937_64 rng( 20261016 );

static int64_t uniform( int64_t lo, int64_t hi ) { return std::uniform_int_distribution<int64_t>( lo, hi )( rng ); }
static double uniformReal( double lo, double hi ) { return std::uniform_real_distribution<double>( lo, hi )( rng ); }
static bool chance( int percent ) { return uniform( 0, 99 ) < percent; }

static json pt( const Point64& p ) { return json::array( { p.x, p.y, p.z } ); }

static json pathJSON( const Path64& path )
{
    json a = json::array();

    for( const Point64& p : path )
        a.push_back( pt( p ) );

    return a;
}

static json pathsJSON( const Paths64& paths )
{
    json a = json::array();

    for( const Path64& p : paths )
        a.push_back( pathJSON( p ) );

    return a;
}

/// A tree's outlines and holes, each with what it holds, in Clipper2's order
static json treeJSON( const PolyPath64& tree )
{
    json a = json::array();

    for( const auto& child : tree )
        a.push_back( { { "p", pathJSON( child->Polygon() ) }, { "h", child->IsHole() }, { "c", treeJSON( *child ) } } );

    return a;
}

// The z values the points are given: each its own (as KiCad numbers them, to find their arcs again), all zero, or a
// few small ones shared between points
static int     zMode = 0;
static int64_t nextZ = 0;

static Point64 point( int64_t x, int64_t y )
{
    int64_t z = zMode == 0 ? nextZ++ : zMode == 1 ? 0 : uniform( 0, 3 );
    return Point64( x, y, z );
}

/// The size of a case's shapes: whole nanometres (a few), small grids, millimetres, up to a metre
struct Scale
{
    int64_t unit;    // a grid step
    int64_t grid;    // steps across
    int64_t ox, oy;  // where the shapes are
};

static Scale randScale()
{
    static const int64_t units[] = { 1, 1, 3, 7, 10, 1000, 100003, 1000000, 10000019 };
    Scale s;
    s.unit = units[uniform( 0, 8 )];
    s.grid = uniform( 2, 12 );
    s.ox = chance( 60 ) ? 0 : uniform( -1000000000, 1000000000 ) / std::max<int64_t>( 1, s.unit ) * s.unit;
    s.oy = chance( 60 ) ? 0 : uniform( -1000000000, 1000000000 ) / std::max<int64_t>( 1, s.unit ) * s.unit;

    // (keeping a metre wide grid within a metre or so of the origin)
    if( s.unit * s.grid > 100000000 )
        s.grid = std::max<int64_t>( 2, 100000000 / s.unit );

    return s;
}

static Point64 gridPoint( const Scale& s )
{
    return point( s.ox + uniform( 0, s.grid ) * s.unit, s.oy + uniform( 0, s.grid ) * s.unit );
}

/// Points round a centre: convex (in angle order, the same radius) or a star (radii of their own), sometimes many
static Path64 roundPath( const Scale& s, bool star, int n )
{
    double  r = std::max<double>( 2.0, (double) s.unit * s.grid / 2 ) * uniformReal( 0.3, 1.0 );
    int64_t cx = s.ox + s.unit * s.grid / 2, cy = s.oy + s.unit * s.grid / 2;
    std::vector<double> angles;

    for( int i = 0; i < n; i++ )
        angles.push_back( chance( 70 ) ? 2 * M_PI * i / n : uniformReal( 0, 2 * M_PI ) );

    std::sort( angles.begin(), angles.end() );
    Path64 path;

    for( double a : angles )
    {
        double rr = star ? r * uniformReal( 0.2, 1.0 ) : r;
        path.push_back( point( cx + (int64_t) std::llround( rr * cos( a ) ), cy + (int64_t) std::llround( rr * sin( a ) ) ) );
    }

    return path;
}

static Path64 rectPath( int64_t x0, int64_t y0, int64_t x1, int64_t y1 )
{
    return Path64{ point( x0, y0 ), point( x1, y0 ), point( x1, y1 ), point( x0, y1 ) };
}

/// A comb: teeth as tall as the comb (edges that each cross most of its height), on a base `base` steps high
static Path64 combPath( const Scale& s, int teeth, int64_t base )
{
    int64_t w = std::max<int64_t>( 1, s.unit ), h = s.unit * s.grid * 3 + 7 + base * w;
    Path64  path;

    for( int i = 0; i < teeth; i++ )
    {
        path.push_back( point( s.ox + 2 * i * w, s.oy - h ) );
        path.push_back( point( s.ox + ( 2 * i + 1 ) * w, s.oy - h ) );
        path.push_back( point( s.ox + ( 2 * i + 1 ) * w, s.oy - base * w ) );
        path.push_back( point( s.ox + ( 2 * i + 2 ) * w, s.oy - base * w ) );
    }

    path.push_back( point( s.ox + 2 * teeth * w, s.oy ) );
    path.push_back( point( s.ox, s.oy ) );
    return path;
}

/// A closed path, or several (an outline with holes): on a small grid (collinear, touching, repeated points and
/// crossings come often), round, a star, rectangles, anywhere in a box, combs, a few points or none
static Paths64 randClosed( const Scale& s )
{
    Paths64 out;
    Path64  path;

    switch( uniform( 0, 13 ) )
    {
    case 0:
    case 1:
    case 2:
    {
        int n = (int) uniform( 3, 12 );

        for( int i = 0; i < n; i++ )
            path.push_back( gridPoint( s ) );

        break;
    }
    case 3: path = roundPath( s, false, (int) uniform( 3, chance( 30 ) ? 160 : 24 ) ); break;
    case 4: path = roundPath( s, true, (int) uniform( 3, chance( 30 ) ? 120 : 24 ) ); break;
    case 5:
    {
        int64_t x0 = uniform( 0, s.grid ), x1 = uniform( 0, s.grid ), y0 = uniform( 0, s.grid ), y1 = uniform( 0, s.grid );
        path = rectPath( s.ox + x0 * s.unit, s.oy + y0 * s.unit, s.ox + x1 * s.unit, s.oy + y1 * s.unit );
        break;
    }
    case 6:
    {
        // an outline with a hole or two (and a hole in a hole), turned the other way round, or not
        int64_t g = s.grid * 4 + 8, u = s.unit;
        out.push_back( rectPath( s.ox, s.oy, s.ox + g * u, s.oy + g * u ) );
        Path64 hole = rectPath( s.ox + 2 * u, s.oy + 2 * u, s.ox + ( g / 2 ) * u, s.oy + ( g - 2 ) * u );

        if( chance( 80 ) )
            std::reverse( hole.begin(), hole.end() );

        out.push_back( hole );

        if( chance( 50 ) )
            out.push_back( rectPath( s.ox + 3 * u, s.oy + 3 * u, s.ox + 4 * u, s.oy + 4 * u ) );

        if( chance( 50 ) )
        {
            Path64 h2 = rectPath( s.ox + ( g / 2 + 1 ) * u, s.oy + 2 * u, s.ox + ( g - 2 ) * u, s.oy + ( g / 2 ) * u );
            std::reverse( h2.begin(), h2.end() );
            out.push_back( h2 );
        }

        break;
    }
    case 7:
    {
        // a round outline of many points (more than Clipper2 searches one by one) with holes inside it
        Scale big = s;
        Path64 outline = roundPath( big, chance( 30 ), (int) uniform( 65, 200 ) );
        out.push_back( outline );
        Scale inner = s;
        inner.grid = std::max<int64_t>( 2, s.grid / 3 );
        inner.ox = s.ox + s.unit * s.grid / 3;
        inner.oy = s.oy + s.unit * s.grid / 3;

        for( int i = (int) uniform( 1, 3 ); i > 0; i-- )
        {
            Path64 hole = roundPath( inner, false, (int) uniform( 3, chance( 50 ) ? 80 : 10 ) );

            if( chance( 70 ) )
                std::reverse( hole.begin(), hole.end() );

            out.push_back( hole );
        }

        break;
    }
    case 8:
    {
        // a comb, of few teeth or many, now and then with holes in its base (rings of many points whose edges
        // each cross many stripes: KiCad's stripe index declines them)
        int64_t base = chance( 50 ) ? 1 : 4;
        int     teeth = (int) uniform( 2, chance( 50 ) ? 40 : 120 );
        out.push_back( combPath( s, teeth, base ) );

        if( base > 1 )
        {
            int64_t w = std::max<int64_t>( 1, s.unit );

            for( int i = (int) uniform( 1, 3 ); i > 0; i-- )
            {
                int64_t x = uniform( 0, 2 * teeth - 2 ) * w;
                Path64  hole = rectPath( s.ox + x + 1, s.oy - 3 * w + 1, s.ox + x + 2 * w - 1, s.oy - w - 1 );

                if( chance( 70 ) )
                    std::reverse( hole.begin(), hole.end() );

                out.push_back( hole );
            }
        }

        break;
    }
    case 9:
    {
        // anywhere in a box: crossings everywhere
        int n = (int) uniform( 3, 30 );

        for( int i = 0; i < n; i++ )
            path.push_back( point( s.ox + uniform( 0, s.unit * s.grid ), s.oy + uniform( 0, s.unit * s.grid ) ) );

        break;
    }
    case 10:
    {
        // repeated points, collinear runs, a last point that is the first again
        int n = (int) uniform( 3, 10 );
        Point64 p = gridPoint( s );

        for( int i = 0; i < n; i++ )
        {
            path.push_back( p );

            if( chance( 30 ) )
                path.push_back( point( p.x, p.y ) );

            if( chance( 50 ) )
            {
                Point64 q = gridPoint( s );
                path.push_back( point( ( p.x + q.x ) / 2, ( p.y + q.y ) / 2 ) );
                p = q;
            }
            else
            {
                p = gridPoint( s );
            }
        }

        if( chance( 50 ) )
            path.push_back( point( path[0].x, path[0].y ) );

        break;
    }
    case 11:
    case 12:
    {
        // flat: long edges that rise by a few units at most, from anywhere, or a fan of them between two far
        // apart columns (their crossings, rounded, can fall outside the scanbeam they are in)
        int     n = (int) uniform( 3, 16 );
        int64_t length = std::min<int64_t>( 1000000000, std::max<int64_t>( 1000, s.unit * s.grid * 1000 ) );
        bool    fan = chance( 50 );
        int64_t rise = uniform( 1, 6 );

        for( int i = 0; i < n; i++ )
        {
            int64_t x = fan ? ( i % 2 == 0 ? uniform( 0, 3 ) : length - uniform( 0, 3 ) ) : uniform( 0, length );
            path.push_back( point( s.ox + x, s.oy + uniform( 0, rise ) * ( chance( 80 ) ? 1 : s.unit ) ) );
        }

        break;
    }
    default:
    {
        // a few points, or none
        int n = (int) uniform( 0, 3 );

        for( int i = 0; i < n; i++ )
            path.push_back( gridPoint( s ) );

        break;
    }
    }

    if( out.empty() )
        out.push_back( path );

    if( chance( 50 ) )
    {
        for( Path64& p : out )
            std::reverse( p.begin(), p.end() );
    }

    return out;
}

/// An open path: a polyline on the grid or anywhere, flat or upright now and then, or a closed path left open
static Path64 randOpen( const Scale& s )
{
    Path64 path;

    switch( uniform( 0, 6 ) )
    {
    case 0:
    case 1:
    {
        int n = (int) uniform( 2, 8 );

        for( int i = 0; i < n; i++ )
            path.push_back( gridPoint( s ) );

        break;
    }
    case 5:
    case 6:
    {
        // a zigzag, its runs horizontal or upright now and then
        int     n = (int) uniform( 3, 10 );
        Point64 p = gridPoint( s );
        path.push_back( p );

        for( int i = 1; i < n; i++ )
        {
            int64_t dx = uniform( -3, 3 ) * s.unit, dy = uniform( -3, 3 ) * s.unit;

            if( chance( 30 ) )
                dy = 0;
            else if( chance( 20 ) )
                dx = 0;

            p = point( p.x + dx, p.y + dy );
            path.push_back( p );
        }

        break;
    }
    case 2:
    {
        // flat, or upright
        int     n = (int) uniform( 2, 5 );
        bool    flat = chance( 50 );
        int64_t c = uniform( 0, s.grid ) * s.unit;

        for( int i = 0; i < n; i++ )
        {
            int64_t v = uniform( 0, s.grid ) * s.unit;
            path.push_back( flat ? point( s.ox + v, s.oy + c ) : point( s.ox + c, s.oy + v ) );
        }

        break;
    }
    case 3:
    {
        int n = (int) uniform( 2, 12 );

        for( int i = 0; i < n; i++ )
            path.push_back( point( s.ox + uniform( 0, s.unit * s.grid ), s.oy + uniform( 0, s.unit * s.grid ) ) );

        break;
    }
    default: path = randClosed( s )[0]; break;
    }

    return path;
}

static Paths64 randClosedPaths( const Scale& s, int lo, int hi )
{
    Paths64 out;

    for( int i = (int) uniform( lo, hi ); i > 0; i-- )
    {
        Paths64 p = randClosed( s );
        out.insert( out.end(), p.begin(), p.end() );
    }

    return out;
}

static void startZ()
{
    int m = (int) uniform( 0, 99 );
    zMode = m < 70 ? 0 : m < 85 ? 1 : 2;
    nextZ = 0;
}

/// What `run` writes, run in a child process: nothing when the child dies (Clipper2 has inputs it never finishes,
/// recursing until its stack runs out, and the case is kept, marked as one KiCad's copy crashes on)
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

/// The z callback as KiCad uses it: each intersection gets a z of its own, the next number after the points' (the
/// calls are recorded: the ends' z values of both edges, and the point with the z Clipper2 gave it)
struct ZLog
{
    json    calls = json::array();
    int64_t next = 0;

    ZCallback64 callback()
    {
        return [this]( const Point64& e1bot, const Point64& e1top, const Point64& e2bot, const Point64& e2top,
                       Point64& p )
        {
            calls.push_back( json::array( { e1bot.z, e1top.z, e2bot.z, e2top.z, p.x, p.y, p.z } ) );
            p.z = next++;
        };
    }
};

static json booleanRun( const Paths64& subject, const Paths64& open, const Paths64& clip, int ct, int fr,
                        bool collinear, bool reverse, bool zcb, int64_t defaultZ, int threshold );

static json booleanCase()
{
    startZ();
    Scale   s = randScale();
    Paths64 subject = randClosedPaths( s, 1, 3 );
    Paths64 open;
    Paths64 clip = randClosedPaths( s, 0, 3 );

    // the clip the subject again, moved a little (or not at all): edges along, over and nearly over each other
    if( chance( 12 ) )
    {
        int64_t dx = uniform( -3, 3 ) * ( chance( 50 ) ? 1 : s.unit ), dy = uniform( -3, 3 ) * ( chance( 50 ) ? 1 : s.unit );
        clip.clear();

        for( const Path64& path : subject )
        {
            Path64 moved;

            for( const Point64& q : path )
                moved.push_back( point( q.x + dx, q.y + ( chance( 90 ) ? dy : dy + 1 ) ) );

            if( chance( 50 ) )
                std::reverse( moved.begin(), moved.end() );

            clip.push_back( moved );
        }
    }

    if( chance( 30 ) )
    {
        for( int i = (int) uniform( 1, 4 ); i > 0; i-- )
        {
            // anywhere, or from a corner of a closed path, or to one, or along one
            Path64 p = randOpen( s );

            if( chance( 15 ) && !subject[0].empty() )
            {
                p.clear();

                for( const Point64& q : subject[0] )
                    p.push_back( point( q.x, q.y ) );

                if( chance( 50 ) )
                    p.push_back( point( subject[0][0].x, subject[0][0].y ) );
            }

            if( chance( 30 ) && !p.empty() && !subject[0].empty() )
                p[0] = point( subject[0][0].x, subject[0][0].y );

            if( chance( 20 ) && !p.empty() && !clip.empty() && !clip[0].empty() )
                p.back() = point( clip[0].back().x, clip[0].back().y );

            open.push_back( p );
        }
    }

    int     ct = chance( 2 ) ? 0 : (int) uniform( 1, 4 );
    int     fr = (int) uniform( 0, 3 );
    bool    collinear = chance( 50 ), reverse = chance( 30 ), zcb = chance( 60 );
    int64_t defaultZ = chance( 80 ) ? 0 : -7;
    int     threshold = chance( 70 ) ? 64 : chance( 50 ) ? 0 : 8;
    return booleanRun( subject, open, clip, ct, fr, collinear, reverse, zcb, defaultZ, threshold );
}

/// A boolean operation's case: its input, and what Clipper2 makes of it as paths and as a tree
static json booleanRun( const Paths64& subject, const Paths64& open, const Paths64& clip, int ct, int fr,
                        bool collinear, bool reverse, bool zcb, int64_t defaultZ, int threshold )
{
    json j = { { "subject", pathsJSON( subject ) }, { "open", pathsJSON( open ) }, { "clip", pathsJSON( clip ) },
               { "clipType", ct }, { "fillRule", fr }, { "preserveCollinear", collinear }, { "reverse", reverse },
               { "zCallback", zcb }, { "zBase", nextZ }, { "defaultZ", defaultZ }, { "pipThreshold", threshold } };

    int64_t zBase = nextZ;
    std::optional<std::string> result = isolated( [&]()
    {
        json r;

        for( int asTree = 0; asTree < 2; asTree++ )
        {
            Clipper64 c;
            ZLog      log;
            log.next = zBase;
            c.PreserveCollinear( collinear );
            c.ReverseSolution( reverse );
            c.DefaultZ = defaultZ;
            c.PipIndexThreshold( threshold );

            if( zcb )
                c.SetZCallback( log.callback() );

            c.AddSubject( subject );

            if( !open.empty() )
                c.AddOpenSubject( open );

            c.AddClip( clip );
            Paths64 openOut;

            if( asTree )
            {
                PolyTree64 tree;
                r["treeOk"] = c.Execute( (ClipType) ct, (FillRule) fr, tree, openOut );
                r["tree"] = treeJSON( tree );
                r["treeArea"] = tree.Area();
                r["treeOpen"] = pathsJSON( openOut );
                r["treeCalls"] = log.calls;
            }
            else
            {
                Paths64 closed;
                r["ok"] = c.Execute( (ClipType) ct, (FillRule) fr, closed, openOut );
                r["closed"] = pathsJSON( closed );
                r["openOut"] = pathsJSON( openOut );
                r["calls"] = log.calls;
            }
        }

        return r.dump();
    } );

    if( result )
        j.update( json::parse( *result ) );
    else
        j["crashed"] = true;

    return j;
}

/// Inputs found by searching for ones that take Clipper2 down its rarer ways (KiCad's copy built with counters):
/// splits without points whose splits lead back to them, gone through again (and in the first two, round and round
/// for ever: KiCad's copy crashes on those), a split whose new part holds the rest of its path
static json knownCases()
{
    struct Known
    {
        int                               ct, fr;
        bool                              collinear;
        std::vector<std::vector<int64_t>> subject, clip;  // x, y, x, y, ...
    };

    static const Known known[] = {
        { 4, 0, false,
          { { 2, 0, 999999997, 0, 1, 1, 999999997, 1, 1, 0, 1000000000, 0, 0, 1, 999999999, 1 },
            { 1, 2, 999999999, 0, 3, 2, 999999998, 2, 2, 0 } },
          { { 0, 1, 999999998, 1, 2, 0, 999999997, 0, 3, 1, 999999997, 0, 0, 1, 999999998, 1, 0, 1, 999999997, 0 } } },
        { 4, 0, false,
          { { 3, 0, 999999997, 1, 0, 3, 999999999, 1, 2, 1, 999999997, 0, 3, 2, 999999999, 2, 0, 2, 999999997, 3,
              3, 2, 999999998, 3 },
            { 2, 0, 999999999, 3, 1, 1 } },
          { { 0, 3, 999999999, 0, 1, 3, 1000000000, 0, 3, 3, 999999997, 2, 0, 2, 999999997, 3, 0, 1 } } },
        { 4, 1, false,
          { { 2, 6, 999999997, 4, 3, 3, 999999998, 0 },
            { 2, 2, 999999998, 2, 2, 2, 999999998, 0, 3, 3, 999999999, 1, 1, 3, 999999998, 1 } },
          {} },
        { 3, 0, true,
          { { 1, 6, 999999, 1, 1, 2, 1000000, 3, 0, 6, 999998, 1, 2, 1, 1000000, 2 },
            { 1, 4, 1000000, 0, 0, 0 } },
          { { 1, 0, 999997, 2, 0, 1, 999998, 1, 1, 0, 999998, 2, 2, 1, 999999, 2, 0, 1 } } },
        { 2, 0, false,
          { { 2, 0, 999999, 3, 2, 3, 999999, 2, 1, 4, 999999, 2, 0, 4, 1000000, 1, 0, 1, 999999, 4, 3, 3,
              999997, 4 },
            { 1, 1, 999999, 1, 0, 0, 999998, 0, 0, 0, 999997, 1, 0, 1, 999998, 0, 3, 1 } },
          {} },
        { 2, 2, true,
          { { 2, 2, 1, 3, 5, 1, 0, 5 } },
          { { 4, 3, 4, 5, 4, 3, 5, 2, 0, 0, 0, 5 },
            { 2, 2, 0, 0, 5, 0, 2, 3, 4, 5 } } },
        { 2, 3, false,
          { { 1, 3, 999998, 2, 0, 4, 999999, 0, 0, 3, 999998, 4, 2, 0, 999998, 4, 1, 2, 999998, 3 } },
          { { 0, 6, 999999, 3, 0, 4, 999998, 1 },
            { 1, 3, 999997, 0, 0, 2, 999997, 6, 3, 5, 999997, 6, 0, 4, 999997, 3, 3, 5, 999999, 3 } } },
        { 3, 1, true,
          { { 3, 0, 999999, 1, 0, 1, 999997, 0, 2, 0, 999998, 1, 3, 0 },
            { 3, 1, 1000000, 0, 0, 0 } },
          {} },
        { 4, 1, true,
          { { 1, 3, 999999999, 1, 3, 1, 999999997, 1, 1, 0 } },
          { { 1, 1, 1000000000, 1, 1, 0, 999999998, 3, 1, 5, 999999997, 2 } } },
    };

    json cases = json::array();

    for( const Known& k : known )
    {
        for( int zcb = 0; zcb < 2; zcb++ )
        {
            zMode = 0;
            nextZ = 0;
            auto paths = []( const std::vector<std::vector<int64_t>>& list )
            {
                Paths64 out;

                for( const std::vector<int64_t>& xy : list )
                {
                    Path64 path;

                    for( size_t i = 0; i + 1 < xy.size(); i += 2 )
                        path.push_back( point( xy[i], xy[i + 1] ) );

                    out.push_back( path );
                }

                return out;
            };

            Paths64 subject = paths( k.subject ), clip = paths( k.clip );
            cases.push_back( booleanRun( subject, Paths64(), clip, k.ct, k.fr, k.collinear, false, zcb, 0, 64 ) );
        }
    }

    return cases;
}

static json offsetCase()
{
    startZ();
    Scale s = randScale();
    json  groups = json::array();
    std::vector<std::tuple<Paths64, JoinType, EndType>> added;

    for( int g = chance( 80 ) ? 1 : (int) uniform( 2, 3 ); g > 0; g-- )
    {
        JoinType jt = (JoinType) uniform( 0, 3 );
        int      e = (int) uniform( 0, 99 );
        EndType  et = e < 50 ? EndType::Polygon : e < 60 ? EndType::Joined : e < 75 ? EndType::Butt
                                                : e < 85 ? EndType::Square : EndType::Round;
        Paths64  paths;

        if( et == EndType::Polygon )
        {
            paths = randClosedPaths( s, 1, 2 );
        }
        else
        {
            for( int i = (int) uniform( 1, 3 ); i > 0; i-- )
            {
                Path64 p = chance( 70 ) ? randOpen( s ) : randClosed( s )[0];

                // (an open path needs a point at least; Clipper2 reads its first one)
                if( p.empty() )
                    p.push_back( gridPoint( s ) );

                paths.push_back( p );
            }
        }

        added.emplace_back( paths, jt, et );
        groups.push_back( { { "paths", pathsJSON( paths ) }, { "join", (int) jt }, { "end", (int) et } } );
    }

    // how far: nothing, less than Clipper2 bothers with, a few nanometres, or about the shapes' size; out or in
    double size = (double) s.unit * s.grid;
    double delta;
    int    d = (int) uniform( 0, 99 );

    if( d < 4 )
        delta = 0;
    else if( d < 9 )
        delta = uniformReal( 0, 0.6 );
    else if( d < 14 )
        delta = uniform( 1, 6 ) * 0.5;
    else if( d < 24 )
        delta = (double) uniform( 1, 20 ) * std::max<int64_t>( 1, s.unit / 4 );
    else
        delta = size * uniformReal( 0.01, 0.6 );

    if( chance( 35 ) )
        delta = -delta;

    double miterLimit = chance( 50 ) ? 2.0 : chance( 50 ) ? (double) uniform( 0, 10 ) * 0.5 : uniformReal( 1, 6 );
    double arcTolerance = 0;
    int    a = (int) uniform( 0, 99 );

    // arc tolerance: Clipper2's own (none given), KiCad's (from a number of segments to a circle), or any
    if( a >= 40 && a < 80 )
        arcTolerance = std::abs( delta ) * ( 1.0 - cos( M_PI / (double) uniform( 6, 64 ) ) );
    else if( a >= 80 )
        arcTolerance = std::abs( delta ) * uniformReal( 0.0005, 1.2 );

    bool collinear = chance( 50 ), reverse = chance( 30 ), zcb = chance( 40 ), deltacb = chance( 5 );
    bool simplify = chance( 30 );
    json j = { { "groups", groups }, { "delta", delta }, { "miterLimit", miterLimit },
               { "arcTolerance", arcTolerance }, { "preserveCollinear", collinear }, { "reverse", reverse },
               { "zCallback", zcb }, { "deltaCallback", deltacb }, { "zBase", nextZ } };

    // a delta that changes along the path, from the indexes of the points it joins
    DeltaCallback64 deltaFunction = [delta]( const Path64&, const PathD&, size_t curr, size_t prev )
    {
        return delta * ( 1.0 + 0.25 * (double) ( ( curr + prev ) % 3 ) );
    };

    int64_t zBase = nextZ;
    std::optional<std::string> result = isolated( [&]()
    {
        json r;

        for( int asTree = 0; asTree < 2; asTree++ )
        {
            ClipperOffset co;
            ZLog          log;
            log.next = zBase;
            co.MiterLimit( miterLimit );
            co.ArcTolerance( arcTolerance );
            co.PreserveCollinear( collinear );
            co.ReverseSolution( reverse );

            if( zcb )
                co.SetZCallback( log.callback() );

            for( auto& [paths, jt, et] : added )
            {
                if( paths.size() == 1 )
                    co.AddPath( paths[0], jt, et );
                else
                    co.AddPaths( paths, jt, et );
            }

            if( asTree )
            {
                PolyTree64 tree;

                if( deltacb )
                {
                    co.SetDeltaCallback( deltaFunction );
                    co.Execute( 1.0, tree );
                }
                else
                {
                    co.Execute( delta, tree );
                }

                r["tree"] = treeJSON( tree );
                r["treeCalls"] = log.calls;
            }
            else
            {
                Paths64 out;

                if( deltacb )
                    co.Execute( deltaFunction, out );
                else
                    co.Execute( delta, out );

                r["out"] = pathsJSON( out );
                r["calls"] = log.calls;

                // and as KiCad's inflate does it when asked to simplify: the offset simplified, and its union
                if( simplify )
                {
                    bool   closed = std::get<2>( added[0] ) == EndType::Polygon;
                    double epsilon = arcTolerance > 0 ? arcTolerance : std::abs( delta ) * 0.01;
                    Paths64 simplified = SimplifyPaths( out, epsilon, closed );
                    Clipper64 c2;
                    c2.PreserveCollinear( false );
                    c2.ReverseSolution( false );
                    c2.AddSubject( simplified );
                    PolyTree64 tree;
                    c2.Execute( ClipType::Union, FillRule::Positive, tree );
                    r["simplify"] = { { "epsilon", epsilon }, { "closed", closed }, { "paths", pathsJSON( simplified ) },
                                      { "tree", treeJSON( tree ) } };
                }
            }
        }

        return r.dump();
    } );

    if( result )
        j.update( json::parse( *result ) );
    else
        j["crashed"] = true;

    return j;
}

static json helperCase()
{
    startZ();
    Scale  s = randScale();
    bool   closed = chance( 70 );
    Path64 path = closed ? randClosed( s )[0] : randOpen( s );
    Path64 other = randClosed( s )[0];
    json   j = { { "path", pathJSON( path ) }, { "other", pathJSON( other ) }, { "area", Area( path ) },
                 { "areaBoth", Area( Paths64{ path, other } ) }, { "positive", IsPositive( path ) } };

    // points in the polygon: its corners, the middles of its edges, points near them and anywhere near it
    json pips = json::array();
    std::vector<Point64> probes;

    for( size_t i = 0; i < path.size() && i < 6; i++ )
    {
        const Point64& p = path[uniform( 0, path.size() - 1 )];
        const Point64& q = path[uniform( 0, path.size() - 1 )];
        probes.push_back( p );
        probes.push_back( Point64( ( p.x + q.x ) / 2, ( p.y + q.y ) / 2 ) );
        probes.push_back( Point64( p.x + uniform( -2, 2 ), p.y + uniform( -2, 2 ) ) );
    }

    for( int i = 0; i < 4; i++ )
        probes.push_back( Point64( s.ox + uniform( -1, s.grid + 1 ) * s.unit, s.oy + uniform( -1, s.grid + 1 ) * s.unit ) );

    for( const Point64& p : probes )
        pips.push_back( json::array( { p.x, p.y, (int) PointInPolygon( p, path ) } ) );

    j["pips"] = pips;
    j["contains"] = Path2ContainsPath1( path, other );
    j["containedBy"] = Path2ContainsPath1( other, path );

    json simplified = json::array();

    for( int i = 0; i < 2; i++ )
    {
        double epsilon = chance( 20 ) ? 0 : (double) s.unit * uniformReal( 0, 1.5 );
        bool   asClosed = chance( 50 ) ? closed : !closed;
        simplified.push_back( { { "epsilon", epsilon }, { "closed", asClosed },
                                { "path", pathJSON( SimplifyPath( path, epsilon, asClosed ) ) } } );
    }

    j["simplify"] = simplified;
    double epsilon = (double) s.unit * uniformReal( 0, 1.5 );
    j["rdp"] = { { "epsilon", epsilon }, { "path", pathJSON( RamerDouglasPeucker( path, epsilon ) ) } };
    return j;
}

/// How std::sort (and the heap sort it falls back on) leaves points that compare equal: Clipper2 sorts the
/// crossings of a scanbeam with it, bottom up and then from the left, and which of two at the same point comes first
/// changes the paths it makes
static json sortCase()
{
    struct Item
    {
        Point64 pt;
        int     id;
    };

    auto less = []( const Item& a, const Item& b )
    {
        return ( a.pt.y == b.pt.y ) ? ( a.pt.x < b.pt.x ) : ( a.pt.y > b.pt.y );
    };

    int     n = (int) ( chance( 70 ) ? uniform( 0, 40 ) : uniform( 41, 600 ) );
    int64_t range = chance( 50 ) ? uniform( 1, 4 ) : uniform( 5, 1000 );
    std::vector<Item> items;

    for( int i = 0; i < n; i++ )
        items.push_back( { Point64( uniform( 0, range ), uniform( 0, range ) ), i } );

    // in order already, or the other way, now and then
    if( chance( 20 ) )
        std::sort( items.begin(), items.end(), less );

    if( chance( 10 ) )
        std::reverse( items.begin(), items.end() );

    for( int i = 0; i < n; i++ )
        items[i].id = i;

    json points = json::array();

    for( const Item& it : items )
        points.push_back( json::array( { it.pt.x, it.pt.y } ) );

    std::vector<Item> sorted = items, heap = items;
    std::sort( sorted.begin(), sorted.end(), less );
    std::partial_sort( heap.begin(), heap.end(), heap.end(), less );
    json sortedIds = json::array(), heapIds = json::array();

    for( const Item& it : sorted )
        sortedIds.push_back( it.id );

    for( const Item& it : heap )
        heapIds.push_back( it.id );

    return { { "points", points }, { "sorted", sortedIds }, { "heap", heapIds } };
}

int main( int argc, char** argv )
{
    // clipper [COUNT [SEED]]: COUNT cases of each kind, from the random cases SEED gives (the same each time)
    int n = argc > 1 ? atoi( argv[1] ) : 100;

    if( argc > 2 )
        rng.seed( strtoull( argv[2], nullptr, 10 ) );
    const std::pair<const char*, json ( * )()> kinds[] = {
        { "booleans", booleanCase }, { "offsets", offsetCase }, { "helpers", helperCase }, { "sorts", sortCase }
    };

    // (each case written as it is made: the cases run in child processes, which are quicker made from a small one)
    std::cout << "{";

    for( size_t k = 0; k < std::size( kinds ); k++ )
    {
        std::cout << ( k ? "," : "" ) << json( kinds[k].first ).dump() << ":[";

        int written = 0;

        for( ; written < n; written++ )
            std::cout << ( written ? "," : "" ) << kinds[k].second().dump();

        // (and after the random boolean operations, the known ones)
        if( kinds[k].second == booleanCase )
        {
            for( const json& c : knownCases() )
                std::cout << ( written++ ? "," : "" ) << c.dump();
        }

        std::cout << "]";
    }

    std::cout << "}" << std::endl;
    return 0;
}
