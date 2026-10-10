// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NewPipeExtractor",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NewPipeExtractor", targets: ["NewPipeExtractor"]),
    ],
    targets: [
        .target(name: "NewPipeExtractor"),
        // Petit outil en ligne de commande pour tester l'extracteur contre YouTube en direct.
        .executableTarget(name: "extractor-cli", dependencies: ["NewPipeExtractor"]),
    ]
)
