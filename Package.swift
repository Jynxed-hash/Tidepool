// swift-tools-version: 6.2

import PackageDescription

// The menu-bar app links SwiftUI and only exists when this package is
// evaluated on macOS. Linux CI and local `swift test` still build the
// parsers, the hook installer, and cmb-hook.

var products: [Product] = [
    .library(name: "ProviderKit", targets: ["ProviderKit"]),
    .library(name: "HookBridge", targets: ["HookBridge"]),
    .library(name: "ClaudeKit", targets: ["ClaudeKit"]),
    .executable(name: "cmb-hook", targets: ["cmb-hook"]),
]

var targets: [Target] = [
    .target(name: "ProviderKit"),
    .target(name: "HookBridge"),
    .target(
        name: "ClaudeKit",
        dependencies: ["ProviderKit", "HookBridge"]
    ),
    .executableTarget(
        name: "cmb-hook",
        dependencies: ["HookBridge"]
    ),
    .testTarget(
        name: "TidepoolTests",
        dependencies: ["ProviderKit", "HookBridge", "ClaudeKit"]
    ),
]

#if os(macOS)
products.append(.executable(name: "Tidepool", targets: ["Tidepool"]))
targets.append(
    .executableTarget(
        name: "Tidepool",
        dependencies: ["ProviderKit", "HookBridge", "ClaudeKit"]
    )
)

let package = Package(
    name: "Tidepool",
    platforms: [.macOS(.v26)],
    products: products,
    targets: targets
)
#else
let package = Package(
    name: "Tidepool",
    products: products,
    targets: targets
)
#endif
