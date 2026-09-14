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
    dependencies: [.package(url: "https://github.com/aikdna/kdna-core-swift.git", revision: "0b85375b7e92b9ca4591f92c1e814018a4fb95b8")],
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
