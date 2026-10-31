// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CppIDE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CppIDE", targets: ["CppIDE"]),
        .library(name: "CppIDECore", targets: ["CppIDECore"]),
    ],
    dependencies: [
        // Terminal emulation (VT100/xterm) + PTY process management for the Terminal panel.
        // 1.11.2: the last release before the Metal renderer, which needs the separately
        // downloaded Metal toolchain (Xcode 26+) to build.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2"),
    ],
    targets: [
        // UI-independent pieces: LSP client, Go highlighter, text/position math, file tree.
        .target(name: "CppIDECore"),
        // SwiftUI/AppKit application shell.
        .executableTarget(name: "CppIDE", dependencies: ["CppIDECore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "CppIDECoreTests", dependencies: ["CppIDECore"]),
        .testTarget(name: "CppIDETests", dependencies: ["CppIDE", "CppIDECore"]),
    ]
)
