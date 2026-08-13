// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TStreamKit",
    platforms: [
        .iOS(.v15),
        .tvOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "TStreamKit", targets: ["TStreamKit"]),
    ],
    targets: [
        // Vendored MPEG-1/2 Audio Layer II decoder (Martin Fiedler's kjmp2,
        // zlib license — commercial/App Store safe, no GPL). Used to transcode
        // MP2 broadcast audio to AAC, which AVPlayer can play.
        .target(
            name: "CKJMP2",
            path: "Sources/CKJMP2"
        ),

        // Minimal LGPL FFmpeg, shipped as dynamic frameworks (built from source
        // by scripts/build-ffmpeg.sh: decode only, no GPL/network/muxers).
        // Dynamic linking keeps LGPL v3 §4 relinking intact; see
        // THIRD_PARTY_LICENSES.md. libavcodec robustly decodes the non-IDR
        // interlaced broadcast streams VideoToolbox can't handle; libavformat
        // reads the Matroska/WebM and MP4 containers a server can transcode to.
        .binaryTarget(name: "libavcodec", path: "Frameworks/libavcodec.xcframework"),
        .binaryTarget(name: "libavutil", path: "Frameworks/libavutil.xcframework"),
        .binaryTarget(name: "libswscale", path: "Frameworks/libswscale.xcframework"),
        .binaryTarget(name: "libavfilter", path: "Frameworks/libavfilter.xcframework"),
        .binaryTarget(name: "libavformat", path: "Frameworks/libavformat.xcframework"),
        .binaryTarget(name: "libswresample", path: "Frameworks/libswresample.xcframework"),

        // C shim exposing tiny decode and demux APIs over FFmpeg.
        .target(
            name: "CFFVideoDecoder",
            dependencies: ["libavcodec", "libavutil", "libswscale", "libavfilter",
                           "libavformat", "libswresample"],
            path: "Sources/CFFVideoDecoder",
            cSettings: [.headerSearchPath("ffmpeg")],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]
        ),

        .target(
            name: "TStreamKit",
            dependencies: ["CKJMP2", "CFFVideoDecoder"],
            path: "Sources/TStreamKit"
        ),
        .testTarget(
            name: "TStreamKitTests",
            dependencies: ["TStreamKit", "CFFVideoDecoder"],
            path: "Tests/TStreamKitTests"
        ),
    ],
    // The demuxer/decoder/player are confined to single serial queues. We use
    // the Swift 6 toolchain in language-mode 5 to avoid fighting strict
    // concurrency for queue-confined mutable state. Flip to `.v6` once those
    // types are audited for `Sendable`.
    swiftLanguageModes: [.v5]
)
