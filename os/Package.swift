// swift-tools-version:5.10
// Signal & Noise for macOS (experimental): masks parts of the whole screen that match your bubbles.
// MaskCore is the pure part (Decisions requests, the grid, hashing, image prep) and is unit tested;
// SignalNoiseOS is the menu-bar app; snos-eval runs the same judging over a folder of screenshots.
import PackageDescription

let package = Package(
  name: "SignalNoiseOS",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "SignalNoiseOS", targets: ["SignalNoiseOS"]),
    .executable(name: "snos-eval", targets: ["snos-eval"]),
  ],
  targets: [
    .target(name: "MaskCore"),
    .executableTarget(name: "SignalNoiseOS", dependencies: ["MaskCore"]),
    .executableTarget(name: "snos-eval", dependencies: ["MaskCore"]),
    .testTarget(name: "MaskCoreTests", dependencies: ["MaskCore"]),
  ],
  swiftLanguageVersions: [.v5]
)
