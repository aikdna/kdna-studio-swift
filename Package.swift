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
    ],
    targets: [
        .target(
            name: "KDNAStudioCore",
            dependencies: [
                .product(name: "KDNACore", package: "kdna-core-swift"),
            ]
        ),
        .testTarget(
            name: "KDNAStudioCoreTests",
            dependencies: ["KDNAStudioCore"]
        ),
    ]
)
