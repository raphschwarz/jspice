// What KiCad's router and settings call from the rest of KiCad, as these programs need it: no program object (so the
// thread pool is the router's own), no settings folder (so KiCad's advanced settings are their defaults), and no
// boards (the length calculation's pad and via helpers are never reached: this world has no PADs or PCB_VIAs).
//
// GNU General Public License version 3 or later, as the KiCad code it is linked with.

#include <kiplatform/io.h>
#include <length_delay_calculation/length_delay_calculation.h>
#include <paths.h>
#include <pgm_base.h>

#include <cstdlib>

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
