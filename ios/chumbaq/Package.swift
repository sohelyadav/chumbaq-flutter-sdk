// swift-tools-version: 5.9
// Chumbaq Flutter plugin — iOS Swift package.
//
// The plugin is Swift Package Manager only, with no podspec, because the
// native SDK it wraps (chumbaq-ios-sdk) ships as a Swift package and has no
// CocoaPods spec to depend on. A pod that cannot pull in the SDK would fail
// at `import ChumbaqCore` with "no such module"; a missing podspec makes
// Flutter say what is actually wrong instead:
//
//   The following plugin(s) are only compatible with Swift Package Manager:
//     - chumbaq
//   Try enabling Swift Package Manager by running
//   "flutter config --enable-swift-package-manager" [...]
//
// See README.md ("iOS setup") for the host-app side.

import PackageDescription

// ── Native SDK ───────────────────────────────────────────────────────────────
//
// The published chumbaq-ios-sdk, by tag. Keep `from:` in step with the
// Android side's `chumbaqSdkVersion` in android/build.gradle.kts.

let package = Package(
  name: "chumbaq",
  platforms: [
    // Level with the native SDK (chumbaq-ios-sdk declares `.iOS(.v14)`)
    // rather than above it. Flutter's own floor is higher — 3.47 migrates a
    // host project to a deployment target of 15.0 — so in practice an app
    // building this will be on 15; this floor exists so the plugin is not
    // what rules out iOS 14 if that ever changes.
    .iOS("14.0")
  ],
  products: [
    .library(name: "chumbaq", targets: ["chumbaq"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
    // No `name:` — SwiftPM derives this dependency's identity from the URL
    // ("chumbaq-ios-sdk"), and naming it "Chumbaq" as well would alias a
    // second identity onto the same package, which collides with this
    // package's own identity once Flutter symlinks it into the host app.
    .package(url: "https://github.com/sohelyadav/chumbaq-ios-sdk.git", from: "0.1.0"),
  ],
  targets: [
    .target(
      name: "chumbaq",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        .product(name: "ChumbaqCore", package: "chumbaq-ios-sdk"),
        .product(name: "ChumbaqPush", package: "chumbaq-ios-sdk"),
        .product(name: "ChumbaqBanners", package: "chumbaq-ios-sdk"),
        .product(name: "ChumbaqMessages", package: "chumbaq-ios-sdk"),
      ]
    )
  ]
)
