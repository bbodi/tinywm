// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "tinywm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tinywm", targets: ["tinywm"]),
    ],
    targets: [
        // Geometry, the WindowSystem protocol, clocks, shortcuts and motion constants. No AppKit.
        .target(name: "WindowCore"),
        // The scrolling strip: columns side by side on a strip wider than the screen.
        .target(name: "StripModel", dependencies: ["WindowCore"]),
        .target(name: "StripEngine", dependencies: ["StripModel", "WindowCore"]),
        // Reusable macOS window plumbing: Accessibility I/O, tracking, hotkeys, release on quit.
        .target(name: "WindowKit", dependencies: ["WindowCore"]),
        .executableTarget(name: "tinywm", dependencies: ["StripEngine", "StripModel", "WindowCore", "WindowKit"]),
        .testTarget(name: "StripTests", dependencies: ["StripModel", "StripEngine", "WindowCore"]),
        .testTarget(name: "WindowCoreTests", dependencies: ["WindowCore"]),
    ]
)
