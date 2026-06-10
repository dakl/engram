// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Engram",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EngramCore", targets: ["EngramCore"]),
        .executable(name: "engram", targets: ["engram"]),
    ],
    targets: [
        .target(
            name: "CSQLite",
            cSettings: [
                .headerSearchPath("include"),
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_ENABLE_FTS5"),
                .define("HAVE_USLEEP", to: "1"),
            ]
        ),
        .target(
            name: "EngramCore",
            dependencies: ["CSQLite"],
            linkerSettings: [
                .linkedFramework("NaturalLanguage")
            ]
        ),
        .executableTarget(
            name: "engram",
            dependencies: ["EngramCore"]
        ),
        .testTarget(
            name: "EngramCoreTests",
            dependencies: ["EngramCore"]
        ),
    ]
)
