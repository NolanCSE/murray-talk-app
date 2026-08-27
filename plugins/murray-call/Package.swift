// swift-tools-version: 5.9
import PackageDescription

// Package and product MUST be named MurrayCall: the Capacitor CLI derives
// that from the npm name ("murray-call") and writes it into
// ios/App/CapApp-SPM/Package.swift. MurrayCallCore has no Capacitor or
// UIKit dependency so it can be tested with `swift test` on a plain Mac.
let package = Package(
    name: "MurrayCall",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "MurrayCall", targets: ["MurrayCall"]),
        .library(name: "MurrayCallCore", targets: ["MurrayCallCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(name: "MurrayCallCore", path: "ios/Sources/MurrayCallCore"),
        .target(
            name: "MurrayCall",
            dependencies: [
                "MurrayCallCore",
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/MurrayCall"),
        .testTarget(name: "MurrayCallCoreTests", dependencies: ["MurrayCallCore"],
                    path: "ios/Tests/MurrayCallCoreTests")
    ]
)
