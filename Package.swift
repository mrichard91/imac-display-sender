// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ImacDisplaySender",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ImacDisplaySender", targets: ["ImacDisplaySender"]),
        .executable(name: "idp-probe", targets: ["idp-probe"]),
        .library(name: "IDPProtocol", targets: ["IDPProtocol"]),
        .library(name: "IDPCore", targets: ["IDPCore"]),
    ],
    targets: [
        // Wire format from PROTOCOL.md. Pure Swift, no Apple frameworks beyond Foundation.
        .target(name: "IDPProtocol"),

        // Networking, speed test, link stats and other pure logic. No UI, no private API.
        .target(name: "IDPCore", dependencies: ["IDPProtocol"]),

        // The only place private macOS API (CGVirtualDisplay*) is referenced.
        .target(
            name: "CGVirtualDisplayBridge",
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
        ),

        .executableTarget(
            name: "ImacDisplaySender",
            dependencies: ["IDPProtocol", "IDPCore", "CGVirtualDisplayBridge"]
        ),
        .executableTarget(name: "idp-probe", dependencies: ["IDPProtocol", "IDPCore"]),

        .testTarget(name: "IDPProtocolTests", dependencies: ["IDPProtocol"]),
        .testTarget(name: "IDPCoreTests", dependencies: ["IDPCore", "IDPProtocol"]),
    ]
)
