// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notan",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NotanCore", targets: ["NotanCore"]),
        .library(name: "NotanUI", targets: ["NotanUI"]),
        .executable(name: "notan", targets: ["notan"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0"),
    ],
    targets: [
        .target(name: "NotanCore", dependencies: [.product(name: "MLX", package: "mlx-swift")]),
        .target(name: "NotanUI", dependencies: ["NotanCore"], path: "Sources/NotanApp"),
        .executableTarget(name: "notan", dependencies: ["NotanCore"]),
        .testTarget(
            name: "NotanCoreTests",
            dependencies: ["NotanCore", .product(name: "MLX", package: "mlx-swift")]),
        .testTarget(name: "NotanAppTests", dependencies: ["NotanUI"]),
    ],
    swiftLanguageModes: [.v5]
)
