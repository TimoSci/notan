// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LayerFit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LayerFitCore", targets: ["LayerFitCore"]),
        .library(name: "LayerFitUI", targets: ["LayerFitUI"]),
        .executable(name: "layerfit", targets: ["layerfit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0"),
    ],
    targets: [
        .target(name: "LayerFitCore", dependencies: [.product(name: "MLX", package: "mlx-swift")]),
        .target(name: "LayerFitUI", dependencies: ["LayerFitCore"], path: "Sources/LayerFitApp"),
        .executableTarget(name: "layerfit", dependencies: ["LayerFitCore"]),
        .testTarget(
            name: "LayerFitCoreTests",
            dependencies: ["LayerFitCore", .product(name: "MLX", package: "mlx-swift")]),
        .testTarget(name: "LayerFitAppTests", dependencies: ["LayerFitUI"]),
    ],
    swiftLanguageModes: [.v5]
)
