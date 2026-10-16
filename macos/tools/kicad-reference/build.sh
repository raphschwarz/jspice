#!/bin/sh
# Builds this folder's programs against KiCad's own code: KiCad 10.0.7's sources (libs/kimath, the PCB editor's
# router in pcbnew/router, and the parts of common/ they use) fetched from KiCad's GitLab and compiled as they are.
# Needs a C++20 compiler, wxWidgets 3.2's headers and libraries, and Boost's and GLM's headers (on Ubuntu: g++,
# libwxgtk3.2-dev, libboost-dev, libglm-dev). KICAD_REFERENCE_BUILD is where the sources and objects go.
#
#   build.sh            builds kicad-geometry, kicad-router and kicad-clipper, and writes Tests/KiCadRouterTests/Fixtures/kicad-geometry.json
#                       and kicad-clipper.json
#   build.sh 2000       ... with that many cases of each kind (75 and 25 for the fixtures; more to check more)
#
# kicad-router reads a board and the routes to make on it, as JSON, and writes what KiCad's router does with them
# (scenes.py makes the boards the router tests use).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
version=10.0.7
work=${KICAD_REFERENCE_BUILD:-${TMPDIR:-/tmp}/kicad-reference}
src="$work/kicad-$version"
obj="$work/obj"
mkdir -p "$src" "$obj"

for part in include libs/core libs/kimath libs/kiplatform common pcbnew thirdparty; do
    name=$(echo "$part" | tr / -)
    if [ ! -e "$work/.have-$name" ]; then
        echo "fetching KiCad $version's $part"
        curl -sSfL "https://gitlab.com/kicad/code/kicad/-/archive/$version/kicad-$version.tar.gz?path=$part" | tar xz -C "$work"
        cp -R "$work/kicad-$version-$name/." "$src/"
        rm -rf "$work/kicad-$version-$name"
        touch "$work/.have-$name"
    fi
done

# config.h is made by KiCad's CMake; nothing here needs what it says
mkdir -p "$work/generated"
[ -e "$work/generated/config.h" ] || echo "#pragma once" > "$work/generated/config.h"

CXX=${CXX:-g++}
flags="-std=c++20 -O1 -DUSINGZ -DFMT_HEADER_ONLY -I$work/generated -I$src/libs/kimath/include -I$src/libs/core/include
    -I$src/libs/kiplatform/include -I$src/include -I$src/common -I$src/pcbnew -I$src/pcbnew/router
    -I$src/thirdparty/clipper2/Clipper2Lib/include -I$src/thirdparty/rtree -I$src/thirdparty/nlohmann_json
    -I$src/thirdparty/dynamic_bitset -I$src/thirdparty/magic_enum -I$src/thirdparty/fmt/include
    -I$src/thirdparty/expected/include -I$src/thirdparty/thread-pool $(wx-config --cxxflags)"

# Changes made to KiCad's sources here (patch.py says what and why): ties between obstacles broken by the order
# the items were made in, not their addresses, and a node's items as a branch copies them and the joints virtual
# vias are made for in an order of their own; a missing BOARD_ITEM asked nothing, or asked of router.cpp. Those made
# before .patched-1 changed headers, so everything was compiled again after them; those since change a .cpp only,
# which is then newer than its object.
python3 "$here/patch.py" "$src"
[ -e "$work/.patched-1" ] || touch "$work/.patched-1"

# KiCad's geometry, its polygon clipper, its router (all but its glue to the PCB editor), and what they call of
# common/: advanced settings (their defaults), the router's settings, colours for its debug drawing, ids, units
sources=$(
    ls "$src"/libs/kimath/src/*.cpp "$src"/libs/kimath/src/geometry/*.cpp "$src"/libs/kimath/src/math/*.cpp
    ls "$src"/thirdparty/clipper2/Clipper2Lib/src/*.cpp
    ls "$src"/pcbnew/router/pns_*.cpp "$src"/pcbnew/router/time_limit.cpp | grep -v "pns_kicad_iface\|pns_tool_base"
    for f in advanced_config gal/color4d kiid eda_units origin_transforms thread_pool json_conversions locale_io \
             config_params trace_helpers settings/json_settings settings/nested_settings settings/parameters \
             settings/aui_settings settings/grid_settings settings/bom_settings; do
        echo "$src/common/$f.cpp"
    done
    echo "$here/stubs.cpp"
)

echo "compiling $(echo "$sources" | wc -l) files"
export CXX flags obj work
echo "$sources" | xargs -P "$(nproc 2>/dev/null || sysctl -n hw.ncpu)" -I{} sh -c '
    o="$obj/$(echo "{}" | cksum | cut -d" " -f1)-$(basename "{}" .cpp).o"
    { [ "$o" -nt "{}" ] && [ "$o" -nt "$work/.patched-1" ]; } || $CXX $flags -c "{}" -o "$o"'
objects=$(echo "$sources" | while read -r f; do echo "$obj/$(echo "$f" | cksum | cut -d" " -f1)-$(basename "$f" .cpp).o"; done)

for program in geometry router clipper; do
    $CXX $flags -c "$here/$program.cpp" -o "$work/$program.o"
    # shellcheck disable=SC2086
    $CXX -o "$work/kicad-$program" "$work/$program.o" $objects $(wx-config --libs core,base,aui)
done

fixtures="$here/../../Tests/KiCadRouterTests/Fixtures"
if [ $# -gt 0 ]; then
    "$work/kicad-geometry" "$1" > "$work/kicad-geometry-$1.json"
    echo "$work/kicad-geometry-$1.json: run the tests with KICAD_GEOMETRY_REFERENCE set to it"
    "$work/kicad-clipper" "$1" > "$work/kicad-clipper-$1.json"
    echo "$work/kicad-clipper-$1.json: run the tests with KICAD_CLIPPER_REFERENCE set to it"
else
    "$work/kicad-geometry" 75 > "$fixtures/kicad-geometry.json"
    "$work/kicad-clipper" 25 > "$fixtures/kicad-clipper.json"
    for fixture in kicad-geometry kicad-clipper; do
        echo "$fixtures/$fixture.json: $(wc -c < "$fixtures/$fixture.json") bytes"
    done
fi
