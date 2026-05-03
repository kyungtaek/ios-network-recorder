// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NetworkRecorder",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
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
            path: "Sources/NetworkRecorder",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NetworkRecorderTests",
            dependencies: ["NetworkRecorder"],
            path: "Tests/NetworkRecorderTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
