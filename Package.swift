// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DoubaoAutoSend",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "doubao-im-auto-send",
            targets: ["DoubaoAutoSend"]
        )
    ],
    targets: [
        .executableTarget(
            name: "DoubaoAutoSend",
            path: "Sources/DoubaoAutoSend"
        )
    ],
    swiftLanguageModes: [
        .v5
    ]
)
