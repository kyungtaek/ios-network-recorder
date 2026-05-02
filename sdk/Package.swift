// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NetworkRecorder",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "NetworkRecorder",
            targets: ["NetworkRecorder"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/Moya/Moya.git", from: "15.0.0")
    ],
    targets: [
        .target(
            name: "NetworkRecorder",
            dependencies: ["Moya"],
            path: "Sources/NetworkRecorder"
        ),
        .testTarget(
            name: "NetworkRecorderTests",
            dependencies: ["NetworkRecorder"],
            path: "Tests/NetworkRecorderTests"
        )
    ]
)
