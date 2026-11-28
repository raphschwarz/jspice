// Callbacks for KiCad's footprint checks, called through KiCad's own pcbnew Python module (footprint-checker.py).
// KiCad's FOOTPRINT::CheckShortingPads, CheckClippedSilk, CheckPads, CheckNetTies, CheckNetTiePadGroups and
// CheckFootprintAttributes (pcbnew/footprint.cpp, KiCad 10.0.8) take a std::function, which the module's SWIG wrappers
// take only as a pointer to one of their own type and make none of: this makes them, each calling a plain C function
// back with what KiCad gives it (items as their addresses, positions as two numbers, messages as UTF-8), and
// footprint-checker.py hands each to KiCad as a SWIG pointer of the type its wrapper asks for. A std::function's
// layout and its call do not depend on the types it names (a pointer is a pointer, a reference an address), so these
// name none of KiCad's. A wxString holds its text as a std::wstring first (wxWidgets 3.2, wxUSE_STD_STRING), which is
// how a message is read. Copyright The KiCad Developers, see KiCad's AUTHORS.txt (for the functions it calls). GNU
// General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).
//
// Built by footprint-checker.py: g++ -std=c++17 -shared -fPIC -O1 callbacks.cpp -o callbacks.so

#include <codecvt>
#include <functional>
#include <locale>
#include <string>

struct XY
{
    int x;
    int y;
};

static std::string utf8( const std::wstring* aText )
{
    std::wstring_convert<std::codecvt_utf8<wchar_t>> conv;
    return conv.to_bytes( *aText );
}

extern "C"
{
// CheckShortingPads: void( const PAD*, const PAD*, int aErrorCode, const VECTOR2I& )
typedef void ( *PAIR_CB )( const void*, const void*, int, int, int );

void* make_pair_fn( PAIR_CB aCb )
{
    return new std::function<void( const void*, const void*, int, const XY& )>(
            [aCb]( const void* a, const void* b, int code, const XY& p ) { aCb( a, b, code, p.x, p.y ); } );
}

// CheckClippedSilk: void( BOARD_ITEM*, BOARD_ITEM*, const VECTOR2I& )
typedef void ( *SILK_CB )( const void*, const void*, int, int );

void* make_silk_fn( SILK_CB aCb )
{
    return new std::function<void( void*, void*, const XY& )>(
            [aCb]( void* a, void* b, const XY& p ) { aCb( a, b, p.x, p.y ); } );
}

// CheckNetTies: void( const BOARD_ITEM*, const BOARD_ITEM*, const BOARD_ITEM*, const VECTOR2I& )
typedef void ( *TRIPLE_CB )( const void*, const void*, const void*, int, int );

void* make_triple_fn( TRIPLE_CB aCb )
{
    return new std::function<void( const void*, const void*, const void*, const XY& )>(
            [aCb]( const void* a, const void* b, const void* c, const XY& p ) { aCb( a, b, c, p.x, p.y ); } );
}

// CheckPads: void( const PAD*, int aErrorCode, const wxString& )
typedef void ( *PAD_MSG_CB )( const void*, int, const char* );

void* make_pad_msg_fn( PAD_MSG_CB aCb )
{
    return new std::function<void( const void*, int, const std::wstring& )>(
            [aCb]( const void* pad, int code, const std::wstring& msg ) { aCb( pad, code, utf8( &msg ).c_str() ); } );
}

// BuildCourtyardCaches' OUTLINE_ERROR_HANDLER: void( const wxString&, BOARD_ITEM*, BOARD_ITEM*, const VECTOR2I& )
typedef void ( *OUTLINE_CB )( const char*, const void*, const void*, int, int );

void* make_outline_fn( OUTLINE_CB aCb )
{
    return new std::function<void( const std::wstring&, void*, void*, const XY& )>(
            [aCb]( const std::wstring& msg, void* a, void* b, const XY& p )
            {
                aCb( utf8( &msg ).c_str(), a, b, p.x, p.y );
            } );
}

// CheckNetTiePadGroups and CheckFootprintAttributes: void( const wxString& )
typedef void ( *MSG_CB )( const char* );

void* make_msg_fn( MSG_CB aCb )
{
    return new std::function<void( const std::wstring& )>(
            [aCb]( const std::wstring& msg ) { aCb( utf8( &msg ).c_str() ); } );
}
}
