// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CursorDisk",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CursorDisk", targets: ["CursorDisk"])
    ],
    targets: [
        .target(
            name: "CursorDisk",
            path: "CursorDisk/Modules",
            exclude: ["UI", "Core/Indexing/FileIndexActor.swift"]
        ),
        .testTarget(
            name: "CursorDiskTests",
            dependencies: ["CursorDisk"],
            path: "CursorDiskTests"
        )
    ]
)
