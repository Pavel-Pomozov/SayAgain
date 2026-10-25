// swift-tools-version: 6.2
import PackageDescription
#if canImport(AppleProductTypes)
import AppleProductTypes
let appExclusions: [String] = []
let demoProduct: Product = .iOSApplication(
    name: "SayAgainChallenge", targets: ["SayAgainChallenge"],
    bundleIdentifier: "org.sayagain.challenge", displayVersion: "1.0", bundleVersion: "1",
    iconAssetName: "AppIcon", supportedDeviceFamilies: [.phone, .pad],
    supportedInterfaceOrientations: [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight])
#else
let appExclusions = ["Resources"]
// Command-line SwiftPM supports core tests and a desktop demo executable.
// Xcode opens the .swiftpm as an iOS app playground through AppleProductTypes.
let demoProduct: Product = .executable(name: "SayAgainChallenge", targets: ["SayAgainChallenge"])
#endif

let package = Package(
    name: "SayAgainChallenge",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "SayAgainCore", targets: ["SayAgainCore"]),
        .library(name: "SayAgainAudio", targets: ["SayAgainAudio"]),
        .library(name: "SayAgainDemo", targets: ["SayAgainDemo"]),
        demoProduct
    ],
    targets: [
        .target(name: "SayAgainCore"),
        .target(name: "SayAgainAudio"),
        .target(name: "SayAgainDemo", dependencies: ["SayAgainCore", "SayAgainAudio"]),
        .executableTarget(name: "SayAgainChallenge", dependencies: ["SayAgainDemo"], exclude: appExclusions),
        .testTarget(name: "SayAgainCoreTests", dependencies: ["SayAgainCore"]),
        .testTarget(name: "SayAgainAudioTests", dependencies: ["SayAgainAudio"])
    ],
    swiftLanguageModes: [.v6]
)
