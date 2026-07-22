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
            revision: "95f638e2f0472a375704fb5fe2f057de0cb4cb07"
        ),
        .package(
            url: "https://github.com/aikdna/kdna-app-shared.git",
            revision: "40f2b8713f7a9e98c74684a256060cd4ca4ba651"
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
