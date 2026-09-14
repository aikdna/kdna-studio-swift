// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kdna-studio-swift",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(
            name: "KDNAStudioCore",
            targets: ["KDNAStudioCore"]
        ),
    ],
    dependencies: [.package(url: "https://github.com/aikdna/kdna-core-swift.git", revision: "7f686046ce8bae968f9645420ff736f5a0aa2091")],
    targets: [
        .target(
            name: "KDNAStudioCore",
            dependencies: [
                .product(name: "KDNACore", package: "kdna-core-swift"),
            ],
            path: "Sources/ComponentCreation"
        ),
        .testTarget(
            name: "KDNAStudioCoreTests",
            dependencies: ["KDNAStudioCore"],
            path: "Tests/ComponentCreationTests",
            resources: [.copy("Resources")]
        ),
    ]
)
