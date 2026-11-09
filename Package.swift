// swift-tools-version: 6.2
import Foundation
import PackageDescription

let localFFI = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .appendingPathComponent("Sources/CRusshFFI.xcframework")

let ffi: Target =
  FileManager.default.fileExists(atPath: localFFI.path)
  ? .binaryTarget(
    name: "CRusshFFI",
    path: "Sources/CRusshFFI.xcframework"
  )
  : .binaryTarget(
    name: "CRusshFFI",
    url: "https://github.com/kosolabs/swift-russh/releases/download/v0.7.0/CRusshFFI.xcframework.zip",
    checksum: "cc2296187a702b7a15878a87c8c4ab6a4ab9ae8ef228123bc26db777557b1363"
  )

let package = Package(
  name: "swift-russh",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(
      name: "SwiftRussh",
      targets: ["SwiftRussh"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2")
  ],
  targets: [
    ffi,
    .target(
      name: "RusshFFI",
      dependencies: ["CRusshFFI"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
      name: "SwiftRussh",
      dependencies: ["RusshFFI"]
    ),
    .executableTarget(
      name: "SwiftSSH",
      dependencies: [
        "SwiftRussh",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "SwiftRusshTests",
      dependencies: ["SwiftRussh"]
    ),
  ]
)
