// swift-tools-version: 5.9
import PackageDescription

// Pure Swift, no Capacitor, no UIKit: this is the part that runs under
// `swift test` on a plain Mac runner. The plugin package next door depends
// on it by path.
let package = Package(
    name: "MurrayCallCore",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [.library(name: "MurrayCallCore", targets: ["MurrayCallCore"])],
    targets: [
        .target(name: "MurrayCallCore", path: "Sources/MurrayCallCore"),
        .testTarget(name: "MurrayCallCoreTests", dependencies: ["MurrayCallCore"],
                    path: "Tests/MurrayCallCoreTests")
    ]
)
