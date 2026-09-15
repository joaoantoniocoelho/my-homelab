// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Homelab",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Homelab", targets: ["Homelab"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .target(name: "HomelabCore", resources: [.copy("collector.py")]),
        .executableTarget(name: "Homelab", dependencies: ["HomelabCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "HomelabCoreTests", dependencies: ["HomelabCore"])
    ]
)
