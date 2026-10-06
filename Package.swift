// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ntfy-bar",
    platforms: [.macOS(.v14)],
    targets: [
        // Tiny C shim: the "allow any app" keychain ACL needs SecAccess APIs that are
        // deprecated (but still the only way) — isolated here so Swift builds warning-free.
        .target(
            name: "KeychainShim",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "NtfyBar",
            dependencies: ["KeychainShim"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
