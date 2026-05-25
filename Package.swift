// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kdna-studio-swift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "KDNaStudioCore",
            targets: ["KDNaStudioCore"]
        ),
    ],
    targets: [
        .target(
            name: "KDNaStudioCore",
            dependencies: []
        ),
        .testTarget(
            name: "KDNaStudioCoreTests",
            dependencies: ["KDNaStudioCore"]
        ),
    ]
)
