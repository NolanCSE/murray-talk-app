// swift-tools-version: 5.9
import PackageDescription

// Package and product MUST be named MurrayCall: the Capacitor CLI derives
// that from the npm name ("murray-call") and writes it into
// ios/App/CapApp-SPM/Package.swift. The testable core lives in ./core.
let package = Package(
    name: "MurrayCall",
    platforms: [.iOS(.v15)],
    products: [.library(name: "MurrayCall", targets: ["MurrayCall"])],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
        .package(name: "MurrayCallCore", path: "core")
    ],
    targets: [
        .target(
            name: "MurrayCall",
            dependencies: [
                .product(name: "MurrayCallCore", package: "MurrayCallCore"),
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/MurrayCall")
    ]
)
