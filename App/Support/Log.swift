import Foundation
import OSLog

/// Structured logging (Console.app / `log stream --predicate 'subsystem == "app.dayledger"'`).
/// Interpolated values are private by default in release logs; only mark something `.public` when
/// it can never identify a person, a place, an amount or an account.
enum Log {
    static let subsystem = "app.dayledger"

    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let subscriptions = Logger(subsystem: subsystem, category: "subscriptions")
    static let background = Logger(subsystem: subsystem, category: "background")
    static let metrics = Logger(subsystem: subsystem, category: "metrics")
}
