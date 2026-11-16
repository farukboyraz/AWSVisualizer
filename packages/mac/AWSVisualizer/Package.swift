// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AWSVisualizer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AWSVisualizer", targets: ["AWSVisualizer"])
    ],
    dependencies: [
        // Real PTY-backed terminal emulator (VT100/xterm parsing, colors,
        // cursor control) for the embedded Terminal panel - writing our own
        // ANSI parser from scratch isn't something to attempt in one pass.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "AWSVisualizer",
            dependencies: ["SwiftTerm"],
            path: "Sources",
            resources: [.copy("Resources")]
        )
    ]
)
