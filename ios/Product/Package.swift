// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWeightsCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OpenWeightsCore", targets: ["OpenWeightsCore"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup", exact: "2.13.5"),
                   .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.5.0")],
    targets: [.target(name: "OpenWeightsCore", dependencies: ["SwiftSoup", .product(name: "Markdown", package: "swift-markdown")], linkerSettings: [.linkedLibrary("iconv")]), .testTarget(name: "OpenWeightsCoreTests", dependencies: ["OpenWeightsCore"], resources: [.copy("Fixtures")])]
)
