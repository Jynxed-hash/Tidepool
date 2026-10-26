// swift-tools-version: 6.2

import PackageDescription

// The menu-bar app links SwiftUI and only exists when this package is
// evaluated on macOS. Linux CI and local `swift test` still build the
// parsers, the hook installer, and cmb-hook.

var products: [Product] = [
    .library(name: "ProviderKit", targets: ["ProviderKit"]),
    .library(name: "HookBridge", targets: ["HookBridge"]),
    .library(name: "ClaudeKit", targets: ["ClaudeKit"]),
    .library(name: "CodexKit", targets: ["CodexKit"]),
    .library(name: "GrokKit", targets: ["GrokKit"]),
    .library(name: "MeterKit", targets: ["MeterKit"]),
    .executable(name: "cmb-hook", targets: ["cmb-hook"]),
]

var testDependencies: [Target.Dependency] = [
    "ProviderKit",
    "HookBridge",
    "ClaudeKit",
    "CodexKit",
    "GrokKit",
    "MeterKit",
]
#if os(macOS)
testDependencies.append("Tidepool")
#endif

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
    .target(
        name: "CodexKit",
        dependencies: ["ProviderKit"]
    ),
    .target(
        name: "GrokKit",
        dependencies: ["ProviderKit"]
    ),
    .target(
        name: "MeterKit",
        dependencies: ["ProviderKit"]
    ),
    .testTarget(
        name: "TidepoolTests",
        dependencies: testDependencies
    ),
]

#if os(macOS)
products.append(.executable(name: "Tidepool", targets: ["Tidepool"]))
targets.append(
    .executableTarget(
        name: "Tidepool",
        dependencies: ["ProviderKit", "HookBridge", "ClaudeKit", "CodexKit", "GrokKit", "MeterKit"]
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
