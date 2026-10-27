// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "new_deeplinks",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "new-deeplinks", targets: ["new_deeplinks"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "new_deeplinks",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
