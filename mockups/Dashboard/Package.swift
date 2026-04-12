// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DashboardMockup",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DashboardMockup", path: "Sources"),
    ]
)
