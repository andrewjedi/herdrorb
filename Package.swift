// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HerdrOrb",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 0.6 retains compatibility with the app's Swift 6.0 build requirement.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.6.0"),
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.20.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "HerdrOrb",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "Markdown", package: "swift-markdown")],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "HerdrOrbTests",
            dependencies: ["HerdrOrb"],
            path: "UnitTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
