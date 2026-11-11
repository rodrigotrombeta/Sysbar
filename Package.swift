// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sysbar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sysbar",
            path: "Sources/Sysbar",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
