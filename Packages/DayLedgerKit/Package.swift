// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DayLedgerKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SharedModels", targets: ["SharedModels"]),
        .library(name: "Networking", targets: ["Networking"]),
        .library(name: "SecureStore", targets: ["SecureStore"]),
        .library(name: "BankKit", targets: ["BankKit"]),
        .library(name: "CalendarKit", targets: ["CalendarKit"]),
        .library(name: "LocationKit", targets: ["LocationKit"]),
        .library(name: "AIKit", targets: ["AIKit"]),
    ],
    targets: [
        // Pure value types shared by the app, the widget and every feature module.
        .target(name: "SharedModels"),
        // HTTP transport, error mapping and OAuth token types. No feature knowledge.
        .target(name: "Networking", dependencies: ["SharedModels"]),
        // Keychain wrapper. The only module that touches Security.framework.
        .target(name: "SecureStore"),
        // Open Banking (TrueLayer) client, mapping and categorisation.
        .target(name: "BankKit", dependencies: ["SharedModels", "Networking", "SecureStore"]),

        // Google OAuth (PKCE), Calendar API, and visit <-> transaction matching.
        .target(name: "CalendarKit", dependencies: ["SharedModels", "Networking", "SecureStore"]),
        // CoreLocation visit monitoring and MapKit place lookup.
        .target(name: "LocationKit", dependencies: ["SharedModels"]),

        // Opt-in AI scheduling assistant: provider protocol, anonymised summary, proposal parsing.
        .target(name: "AIKit", dependencies: ["SharedModels", "Networking"]),

        .testTarget(name: "AIKitTests", dependencies: ["AIKit", "SharedModels", "Networking"]),
        .testTarget(name: "CalendarKitTests", dependencies: ["CalendarKit", "SharedModels", "Networking", "SecureStore"]),
        .testTarget(name: "SharedModelsTests", dependencies: ["SharedModels"]),
        .testTarget(name: "BankKitTests", dependencies: ["BankKit", "SharedModels", "Networking", "SecureStore"]),
    ]
)
