#!/bin/sh
# KiCadKit's, KiCadLink's and KiCadRouter's tests where KiCad 10 is installed on Linux (CI's macOS runners have no
# KiCad): a package of just those targets, as the repository's package also has the macOS app's, built from the
# repository's own sources
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
mkdir -p "$work/Sources" "$work/Tests"
for target in KiCadKit KiCadLink KiCadRouter; do
    ln -s "$root/Sources/$target" "$work/Sources/$target"
    ln -s "$root/Tests/${target}Tests" "$work/Tests/${target}Tests"
done
# the same SwiftProtobuf as the app's
cp "$root/Package.resolved" "$work/"
cat > "$work/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KiCadCheck",
    dependencies: [.package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")],
    targets: [
        .target(name: "KiCadKit"),
        .target(name: "KiCadLink", dependencies: ["KiCadKit", .product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .testTarget(name: "KiCadKitTests", dependencies: ["KiCadKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "KiCadLinkTests", dependencies: ["KiCadLink", "KiCadKit"]),
        .target(name: "KiCadRouter", dependencies: ["KiCadKit"]),
        .testTarget(name: "KiCadRouterTests", dependencies: ["KiCadRouter", "KiCadKit"], resources: [.copy("Fixtures")]),
    ]
)
EOF
cd "$work"
swift test "$@"
