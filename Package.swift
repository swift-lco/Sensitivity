// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Sensitivity",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Detection, scoring and replacement of sensitive data in text.
        .library(
            name: "Sensitivity",
            targets: ["Sensitivity"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Primitives.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Matching.git", branch: "master"),
        .package(url: "https://github.com/swift-langs/Tokens.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "Sensitivity",
            dependencies: [
                .product(name: "Primitives", package: "Primitives"),
                .product(name: "Matching", package: "Matching"),
                .product(name: "Tokens", package: "Tokens"),
            ]
        ),
    ]
)
