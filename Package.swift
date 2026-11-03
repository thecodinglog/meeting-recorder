// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "MeetingRecorder", path: "Sources"),
        .testTarget(name: "MeetingRecorderTests", dependencies: ["MeetingRecorder"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
