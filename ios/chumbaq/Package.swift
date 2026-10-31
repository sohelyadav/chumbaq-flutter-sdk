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

import Foundation
import PackageDescription

// ── Native SDK location ──────────────────────────────────────────────────────
//
// The iOS SDK is consumed from the sibling checkout in the Chumbaq workspace
// — the iOS counterpart of the Android bridge's `mavenLocal()` arrangement
// (see android/build.gradle.kts), and for the same reason: the native SDK is
// not published yet. chumbaq-ios-sdk has no tagged release, so a
// `.package(url:, from:)` dependency could not resolve at all.
//
// DEV WORKFLOW: check out chumbaq-ios-sdk next to chumbaq-flutter-sdk:
//
//   chumbaq/
//     chumbaq-flutter-sdk/   <- this repo
//     chumbaq-ios-sdk/       <- native SDK
//
// Once chumbaq-ios-sdk publishes a tag, replace the `.package(path:)` below
// with:
//
//   .package(url: "https://github.com/sohelyadav/chumbaq-ios-sdk.git", from: "0.1.0")
//
// `resolvingSymlinksInPath` matters: Flutter symlinks this package into the
// host app's `ios/Flutter/ephemeral/Packages/.packages/chumbaq`, and SwiftPM
// resolves relative dependency paths against that symlink rather than against
// this file's real location.
let manifestDirectory = URL(fileURLWithPath: #filePath)
  .resolvingSymlinksInPath()
  .deletingLastPathComponent()

let nativeSdkDirectory =
  manifestDirectory  // <repo>/ios/chumbaq
  .deletingLastPathComponent()  // <repo>/ios
  .deletingLastPathComponent()  // <repo>
  .deletingLastPathComponent()  // the workspace holding both repos
  .appendingPathComponent("chumbaq-ios-sdk")

if !FileManager.default.fileExists(
  atPath: nativeSdkDirectory.appendingPathComponent("Package.swift").path)
{
  // Fails manifest evaluation rather than the compile that would follow,
  // so the message names the actual problem.
  fatalError(
    """
    The Chumbaq iOS SDK was not found at \(nativeSdkDirectory.path).

    The Flutter plugin builds against a sibling checkout of chumbaq-ios-sdk:

      chumbaq/
        chumbaq-flutter-sdk/
        chumbaq-ios-sdk/

    Clone it there, or edit ios/chumbaq/Package.swift to point at your copy.
    """
  )
}

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
    // No `name:` — SwiftPM derives this dependency's identity from the
    // directory ("chumbaq-ios-sdk"), and naming it "Chumbaq" as well would
    // alias a second identity onto the same package, which collides with
    // this package's own identity once Flutter symlinks it into the host app.
    .package(path: nativeSdkDirectory.path),
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
