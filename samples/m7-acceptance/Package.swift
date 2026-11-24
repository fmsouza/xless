// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "M7Acceptance",
    platforms: [.iOS("17.0")],
    products: [.library(name: "M7Acceptance", targets: ["M7Acceptance"])],
    targets: [.target(name: "M7Acceptance", path: "Sources/M7Acceptance")]
)
