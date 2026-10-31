// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "T3QuotaBar", platforms: [.macOS(.v14)], products: [
    .executable(name: "T3QuotaBar", targets: ["T3QuotaBar"])
], dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
], targets: [
    .executableTarget(name: "T3QuotaBar", dependencies: [.product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources")]),
    .testTarget(name: "T3QuotaBarTests", dependencies: ["T3QuotaBar"])
], swiftLanguageModes: [.v5])
