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
        .target(
            name: "TStreamKit",
            path: "Sources/TStreamKit"
        ),
        .testTarget(
            name: "TStreamKitTests",
            dependencies: ["TStreamKit"],
            path: "Tests/TStreamKitTests"
        ),
    ],
    // The pipeline relies on classes confined to a single serial queue. We use
    // the Swift 6 toolchain in language-mode 5 to avoid fighting strict
    // concurrency for queue-confined mutable state. Flip to `.v6` once the
    // pipeline types are audited for `Sendable`.
    swiftLanguageModes: [.v5]
)
