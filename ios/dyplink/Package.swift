// swift-tools-version: 5.9
// Dyplink Flutter plugin — iOS Swift package.
//
// The plugin is Swift Package Manager only, with no podspec, because the
// native SDK it wraps (dyplink-ios-sdk) ships as a Swift package and has no
// CocoaPods spec to depend on. A pod that cannot pull in the SDK would fail
// at `import DyplinkCore` with "no such module"; a missing podspec makes
// Flutter say what is actually wrong instead:
//
//   The following plugin(s) are only compatible with Swift Package Manager:
//     - dyplink
//   Try enabling Swift Package Manager by running
//   "flutter config --enable-swift-package-manager" [...]
//
// See README.md ("iOS setup") for the host-app side.

import Foundation
import PackageDescription

// ── Native SDK location ──────────────────────────────────────────────────────
//
// The iOS SDK is consumed from the sibling checkout in the Dyplink workspace
// — the iOS counterpart of the Android bridge's `mavenLocal()` arrangement
// (see android/build.gradle.kts), and for the same reason: the native SDK is
// not published yet. dyplink-ios-sdk has no tagged release, so a
// `.package(url:, from:)` dependency could not resolve at all.
//
// DEV WORKFLOW: check out dyplink-ios-sdk next to dyplink-flutter-sdk:
//
//   dyplink/
//     dyplink-flutter-sdk/   <- this repo
//     dyplink-ios-sdk/       <- native SDK
//
// Once dyplink-ios-sdk publishes a tag, replace the `.package(path:)` below
// with:
//
//   .package(url: "https://github.com/sohelyadav/dyplink-ios-sdk.git", from: "0.1.0")
//
// `resolvingSymlinksInPath` matters: Flutter symlinks this package into the
// host app's `ios/Flutter/ephemeral/Packages/.packages/dyplink`, and SwiftPM
// resolves relative dependency paths against that symlink rather than against
// this file's real location.
let manifestDirectory = URL(fileURLWithPath: #filePath)
  .resolvingSymlinksInPath()
  .deletingLastPathComponent()

let nativeSdkDirectory =
  manifestDirectory  // <repo>/ios/dyplink
  .deletingLastPathComponent()  // <repo>/ios
  .deletingLastPathComponent()  // <repo>
  .deletingLastPathComponent()  // the workspace holding both repos
  .appendingPathComponent("dyplink-ios-sdk")

if !FileManager.default.fileExists(
  atPath: nativeSdkDirectory.appendingPathComponent("Package.swift").path)
{
  // Fails manifest evaluation rather than the compile that would follow,
  // so the message names the actual problem.
  fatalError(
    """
    The Dyplink iOS SDK was not found at \(nativeSdkDirectory.path).

    The Flutter plugin builds against a sibling checkout of dyplink-ios-sdk:

      dyplink/
        dyplink-flutter-sdk/
        dyplink-ios-sdk/

    Clone it there, or edit ios/dyplink/Package.swift to point at your copy.
    """
  )
}

let package = Package(
  name: "dyplink",
  platforms: [
    // Level with the native SDK (dyplink-ios-sdk declares `.iOS(.v14)`)
    // rather than above it. Flutter's own floor is higher — 3.47 migrates a
    // host project to a deployment target of 15.0 — so in practice an app
    // building this will be on 15; this floor exists so the plugin is not
    // what rules out iOS 14 if that ever changes.
    .iOS("14.0")
  ],
  products: [
    .library(name: "dyplink", targets: ["dyplink"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
    // No `name:` — SwiftPM derives this dependency's identity from the
    // directory ("dyplink-ios-sdk"), and naming it "Dyplink" as well would
    // alias a second identity onto the same package, which collides with
    // this package's own identity once Flutter symlinks it into the host app.
    .package(path: nativeSdkDirectory.path),
  ],
  targets: [
    .target(
      name: "dyplink",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        .product(name: "DyplinkCore", package: "dyplink-ios-sdk"),
        .product(name: "DyplinkPush", package: "dyplink-ios-sdk"),
        .product(name: "DyplinkBanners", package: "dyplink-ios-sdk"),
        .product(name: "DyplinkMessages", package: "dyplink-ios-sdk"),
      ]
    )
  ]
)
