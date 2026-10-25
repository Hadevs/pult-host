import os

/// Unified-log categories; read them with
/// `log stream --predicate 'subsystem == "com.hadevs.pult.host"'`.
enum Log {
    private static let subsystem = "com.hadevs.pult.host"
    static let server = Logger(subsystem: subsystem, category: "server")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let input = Logger(subsystem: subsystem, category: "input")
}
