// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Flameshoter",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "Flameshoter", targets: ["Flameshoter"])],
  targets: [
    .target(
      name: "CWebP", path: "Vendor/libwebp", sources: ["src", "sharpyuv"],
      publicHeadersPath: "src/webp",
      cSettings: [.headerSearchPath("."), .define("WEBP_USE_THREAD")]),
    .target(name: "FlameshoterCore", dependencies: ["CWebP"]),
    .executableTarget(name: "Flameshoter", dependencies: ["FlameshoterCore"]),
    .testTarget(
      name: "FlameshoterCoreTests", dependencies: ["FlameshoterCore", "Flameshoter"],
      resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v5]
)
