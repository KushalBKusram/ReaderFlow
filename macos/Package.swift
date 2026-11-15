// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReaderFlowMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReaderFlowEpisodeLibrary", targets: ["ReaderFlowEpisodeLibrary"]),
        .library(name: "ReaderFlowAudioPlayback", targets: ["ReaderFlowAudioPlayback"]),
        .library(name: "ReaderFlowScriptText", targets: ["ReaderFlowScriptText"]),
        .executable(name: "ReaderFlowMac", targets: ["ReaderFlowMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .target(name: "ReaderFlowEpisodeLibrary"),
        .target(name: "ReaderFlowAudioPlayback", dependencies: ["ReaderFlowEpisodeLibrary"]),
        .target(name: "ReaderFlowScriptText"),
        .executableTarget(name: "ReaderFlowMac", dependencies: [
            "ReaderFlowEpisodeLibrary", "ReaderFlowAudioPlayback", "ReaderFlowScriptText",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ]),
        .testTarget(name: "ReaderFlowMacTests", dependencies: ["ReaderFlowEpisodeLibrary", "ReaderFlowAudioPlayback", "ReaderFlowScriptText"])
    ]
)
