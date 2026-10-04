// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShapeDesk",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ShapeDesk",
            path: "Sources/ShapeDesk"
        )
    ]
)
