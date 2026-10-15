#!/bin/sh
# Generates Sources/KiCadLink/Generated from KiCad's API (the .proto files under proto/, from KiCad 10.0.7's
# api/proto: https://gitlab.com/kicad/code/kicad/-/tree/10.0.7/api/proto), for the version of SwiftProtobuf the
# package depends on.
#
# Needs protoc (3.21 or later) and protoc-gen-swift built from swift-protobuf at that version:
#   git clone --depth 1 --branch 1.38.1 https://github.com/apple/swift-protobuf.git
#   (cd swift-protobuf && swift build -c release --product protoc-gen-swift)
#   PROTOC_GEN_SWIFT=swift-protobuf/.build/release/protoc-gen-swift ./generate.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../../Sources/KiCadLink/Generated"
plugin=${PROTOC_GEN_SWIFT:-$(command -v protoc-gen-swift)}
rm -f "$out"/*.pb.swift
mkdir -p "$out"
cd "$here/proto"
protoc --plugin=protoc-gen-swift="$plugin" --swift_out="$out" --swift_opt=Visibility=Public \
    --swift_opt=FileNaming=PathToUnderscores -I . $(find . -name '*.proto' | sed 's#^\./##' | sort)
echo "generated $(ls "$out" | wc -l | tr -d ' ') files in $out"
