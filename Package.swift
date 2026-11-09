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
    .target(
      name: "CXLSXWriter", path: "Vendor/libxlsxwriter", exclude: ["src/Makefile", "License.txt"],
      sources: ["src", "third_party/minizip/zip.c", "third_party/minizip/ioapi.c"],
      publicHeadersPath: "include", cSettings: [.define("USE_STANDARD_TMPFILE"), .define("USE_NO_MD5")],
      linkerSettings: [.linkedLibrary("z")]),
    .target(name: "FlameshoterCore", dependencies: ["CWebP"]),
    .executableTarget(name: "Flameshoter", dependencies: ["FlameshoterCore", "CXLSXWriter"]),
    .testTarget(
      name: "FlameshoterCoreTests", dependencies: ["FlameshoterCore", "Flameshoter"],
      resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v5]
)
