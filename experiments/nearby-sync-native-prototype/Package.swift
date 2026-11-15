// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReaderFlowNearbySyncNativePrototype",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NearbySyncNative", targets: ["NearbySyncNative"]),
        .executable(name: "readerflow-nearby-sync-native", targets: ["NearbySyncNativeCLI"]),
    ],
    targets: [
        .target(name: "NearbySyncNative"),
        .executableTarget(name: "NearbySyncNativeCLI", dependencies: ["NearbySyncNative"]),
        .testTarget(name: "NearbySyncNativeTests", dependencies: ["NearbySyncNative"]),
    ]
)
