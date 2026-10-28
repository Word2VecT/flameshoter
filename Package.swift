// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Flameshoter",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "Flameshoter", targets: ["Flameshoter"])],
  targets: [
    .target(name: "FlameshoterCore"),
    .executableTarget(name: "Flameshoter", dependencies: ["FlameshoterCore"]),
    .testTarget(
      name: "FlameshoterCoreTests", dependencies: ["FlameshoterCore", "Flameshoter"],
      resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v5]
)
