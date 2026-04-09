// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "InvoiceOrganizer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "InvoiceOrganizer", targets: ["InvoiceOrganizer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "InvoiceOrganizer",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "InvoiceOrganizerTests",
            dependencies: ["InvoiceOrganizer"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
