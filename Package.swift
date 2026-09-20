// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HerdrOrb",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.20.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "HerdrOrb",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
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
