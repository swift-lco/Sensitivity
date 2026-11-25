// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SensitivityBenchmarks",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "b_sensitivity", targets: ["SensitivityBenchmark"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/swift-lco/Matching.git", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "SensitivityBenchmark",
            dependencies: [
                .product(name: "Sensitivity", package: "Sensitivity"),
                .product(name: "Matching", package: "Matching"),
            ]
        ),
    ]
)
