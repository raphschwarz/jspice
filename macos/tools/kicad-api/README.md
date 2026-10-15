# KiCad's API, for the board link

JSpice drives KiCad's PCB editor while it runs through KiCad's own API (KiCad 9 and later: protobuf messages over a
local NNG socket, https://dev-docs.kicad.org/en/apis-and-binding/ipc-api/). `proto/` holds the API's message
definitions as KiCad 10.0.7 has them (GPL 3, from https://gitlab.com/kicad/code/kicad/-/tree/10.0.7/api/proto: the
envelope, the common and editor commands, the board's types and commands, and the files they import);
`generate.sh` makes Swift of them into `Sources/KiCadLink/Generated` with protoc-gen-swift, at the SwiftProtobuf
version `Package.swift` depends on.
