// What KiCad's router and settings call from the rest of KiCad, as these programs need it: no program object (so the
// thread pool is the router's own), no settings folder (so KiCad's advanced settings are their defaults), and no
// boards (the length calculation's pad and via helpers are never reached: this world has no PADs or PCB_VIAs), and
// what a BOARD_ITEM would say of a non-routable item (router.cpp says it, from the board's JSON); and where KiCad's
// router does what is undefined, a stop.
//
// GNU General Public License version 3 or later, as the KiCad code it is linked with.

#include <kiplatform/io.h>
#include <length_delay_calculation/length_delay_calculation.h>
#include <paths.h>
#include <pgm_base.h>

#include <cstdlib>
#include <functional>
#include <iostream>

namespace PNS { class ITEM; }

/// router.cpp's answer to why an item with no BOARD_ITEM cannot be routed from (patch.py has the router ask it)
std::function<wxString( const PNS::ITEM* )> g_kicadReferenceNonRoutableReason;

wxString kicadReferenceNonRoutableReason( const PNS::ITEM* aItem )
{
    return g_kicadReferenceNonRoutableReason ? g_kicadReferenceNonRoutableReason( aItem ) : wxString();
}

/// Where KiCad's router is about to do what is undefined (patch.py has it say so): no reference to be had, so the
/// program stops with exit status 3, as router.cpp stops where it sees such behaviour coming
void kicadReferenceUndefined( const char* aWhat )
{
    std::cerr << "KiCad's router has no defined result here: " << aWhat << "\n";
    std::exit( 3 );
}

PGM_BASE* PgmOrNull()
{
    return nullptr;
}

BS::priority_thread_pool& PGM_BASE::GetThreadPool()
{
    abort();
}

wxString PATHS::GetUserSettingsPath()
{
    return wxS( "/nonexistent-kicad-reference-settings" );
}

bool KIPLATFORM::IO::AtomicWriteFile( const wxString&, const void*, size_t, wxString* )
{
    return false;
}

void LENGTH_DELAY_CALCULATION::OptimiseTraceInPad( SHAPE_LINE_CHAIN&, const PAD*, PCB_LAYER_ID )
{
}

bool LENGTH_DELAY_CALCULATION::IsPointInsideViaPad( const PCB_VIA*, const VECTOR2I&, PCB_LAYER_ID )
{
    return false;
}

void LENGTH_DELAY_CALCULATION::OptimiseTraceInVia( SHAPE_LINE_CHAIN&, const PCB_VIA*, PCB_LAYER_ID )
{
}
