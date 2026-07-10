import Foundation

struct AdapterHealth: Identifiable, Codable, Equatable, Sendable {
    enum Adapter: String, Codable, CaseIterable, Sendable {
        case appServer
        case sqlite
        case rolloutJSONL
        case pluginJournal
        case receipts
    }

    enum Status: Int, Codable, Comparable, Sendable {
        case healthy = 0
        case degraded = 1
        case unavailable = 2

        static func < (lhs: Status, rhs: Status) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let adapter: Adapter
    let status: Status
    let lastSuccessAt: Date?
    let message: String?

    var id: Adapter { adapter }

    var isActionable: Bool {
        if status != .unavailable { return true }
        return adapter != .appServer && adapter != .pluginJournal
    }

    static func healthy(_ adapter: Adapter, at date: Date = .now) -> AdapterHealth {
        AdapterHealth(adapter: adapter, status: .healthy, lastSuccessAt: date, message: nil)
    }

    static func degraded(
        _ adapter: Adapter,
        message: String,
        lastSuccessAt: Date? = nil
    ) -> AdapterHealth {
        AdapterHealth(
            adapter: adapter,
            status: .degraded,
            lastSuccessAt: lastSuccessAt,
            message: message
        )
    }

    static func unavailable(_ adapter: Adapter, message: String) -> AdapterHealth {
        AdapterHealth(
            adapter: adapter,
            status: .unavailable,
            lastSuccessAt: nil,
            message: message
        )
    }
}
