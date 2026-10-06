// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ntfy-bar",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned: the release workflow downloads the matching Sparkle tools (sign_update).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Tiny C shim: the "allow any app" keychain ACL needs SecAccess APIs that are
        // deprecated (but still the only way) — isolated here so Swift builds warning-free.
        .target(
            name: "KeychainShim",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "NtfyBar",
            dependencies: ["KeychainShim", .product(name: "Sparkle", package: "Sparkle")],
            // Notification sounds; build.sh copies them into Contents/Resources (UNNotificationSound looks there).
            resources: [.copy("Resources/Sounds")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            // build.sh embeds Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "NtfyBarTests",
            dependencies: ["NtfyBar"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
