// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentHub", targets: ["AgentHub"]),
        .library(name: "AgentHubCore", targets: ["AgentHubCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        // Platform-independent logic: agent models, launch planning, MCP config,
        // routing, and LLM API streaming. Builds and tests on Linux too.
        .target(name: "AgentHubCore"),
        // The macOS app (SwiftUI + AppKit + SwiftTerm).
        .executableTarget(
            name: "AgentHub",
            dependencies: [
                "AgentHubCore",
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(name: "AgentHubCoreTests", dependencies: ["AgentHubCore"]),
    ]
)
