// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Dataroid",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "Dataroid",
            targets: ["Dataroid"]),
        .library(
            name: "DataroidSnapshot",
            targets: ["DataroidSnapshot"])
    ],
    targets: [
        .binaryTarget(
            name: "Dataroid", 
            path: "Dataroid/DataroidSDK.xcframework"
        ),
        .binaryTarget(
            name: "DataroidSnapshot", 
            path: "DataroidSnapshot/DataroidSnapshotSDK.xcframework"
            )
    ]
)
