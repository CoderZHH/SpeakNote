// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "WorkBenchKit", platforms: [.macOS(.v26), .iOS(.v26)], products: [.library(name: "WorkBenchKit", targets: ["WorkBenchKit"]), .library(name: "WorkBenchActivity", targets: ["WorkBenchActivity"]), .executable(name: "workbench-assistant", targets: ["WorkbenchAssistant"])], targets: [
    .target(name: "WorkBenchActivity"),
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .target(name: "WorkBenchKit", dependencies: ["CSQLite", "WorkBenchActivity"], resources: [.process("Resources")]),
    .executableTarget(name: "WorkbenchAssistant", dependencies: ["WorkBenchKit"]),
    .testTarget(name: "WorkBenchKitTests", dependencies: ["WorkBenchKit", .target(name: "WorkbenchAssistant", condition: .when(platforms: [.macOS]))], resources: [.process("Fixtures")])
])
