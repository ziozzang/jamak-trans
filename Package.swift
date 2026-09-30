// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JamakTrans",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "SRTTranslator", path: "Sources/SRTTranslator")
    ],
    swiftLanguageVersions: [.v5]
)
