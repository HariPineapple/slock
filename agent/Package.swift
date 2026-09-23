// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Slock",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Slock",
            path: "Sources/Slock",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("FoundationModels"),
            ]
        )
    ]
)
