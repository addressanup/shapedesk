// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShapeDesk",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ShapeDeskSorting"),
        .executableTarget(
            name: "ShapeDesk",
            dependencies: ["ShapeDeskSorting"],
            path: "Sources/ShapeDesk"
        ),
        .testTarget(name: "ShapeDeskSortingTests", dependencies: ["ShapeDeskSorting"])
    ]
)
