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
            name: "KDNAStudioCore",
            targets: ["KDNAStudioCore"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/aikdna/kdna-core-swift.git",
            from: "0.21.0"
        ),
        .package(
            url: "https://github.com/aikdna/kdna-app-shared.git",
            revision: "017e759efb448bf99b3384ccafa7f25172169ebb"
        ),
    ],
    targets: [
        .target(
            name: "KDNAStudioCore",
            dependencies: [
                .product(name: "KDNACore", package: "kdna-core-swift"),
                .product(name: "KDNAAppShared", package: "kdna-app-shared"),
            ]
        ),
        .testTarget(
            name: "KDNAStudioCoreTests",
            dependencies: ["KDNAStudioCore"]
        ),
    ]
)
