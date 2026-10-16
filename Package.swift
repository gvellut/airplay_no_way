// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        // The helper is just a normal executable from SPM's perspective.
        .executableTarget(
            name: "AudioMonitorHelper",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit")
            ]
        ),
        // The main application is also a normal executable.
        .executableTarget(
            name: "AudioMonitorLauncher",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
    ]
)
