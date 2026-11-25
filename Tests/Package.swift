// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SensitivityTests",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "t_sensitivity",
            targets: ["SensitivityTests"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-lco/Primitives.git", branch: "master"),
        .package(url: "https://github.com/swift-tooling/Testing.git", branch: "master"),
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "SensitivityTests",
            dependencies: [
                .product(name: "Sensitivity", package: "Sensitivity"),
                .product(name: "Primitives", package: "Primitives"),
                .product(name: "Testing", package: "Testing"),
            ]
        ),
    ]
)
