//
//  DateFormatter+Extensions.swift
//  nmbTrialBeacon
//
//  Date rendering honouring the user's "Date Format" setting.
//

import Foundation

extension Date {
    func formattedWithUserPreference() -> String {
        guard let formatter = UserDateFormat.current.dateFormatter else {
            return formatted(date: .abbreviated, time: .omitted)
        }
        return formatter.string(from: self)
    }

    func formattedWithTimeUserPreference() -> String {
        guard let formatter = UserDateFormat.current.dateTimeFormatter else {
            return formatted(date: .abbreviated, time: .shortened)
        }
        return formatter.string(from: self)
    }
}

/// `DateFormatter` construction is expensive relative to formatting, and these
/// are called from list and detail rows, so one instance per style is cached.
enum UserDateFormat: String {
    case system, us, european, iso

    static var current: UserDateFormat {
        UserDateFormat(rawValue: UserDefaults.standard.string(forKey: "dateFormat") ?? "system") ?? .system
    }

    /// `nil` for `.system`, where `Date.formatted` already does the right thing
    /// for the user's locale.
    var dateFormatter: DateFormatter? { Self.cache.formatter(for: self, withTime: false) }
    var dateTimeFormatter: DateFormatter? { Self.cache.formatter(for: self, withTime: true) }

    private static let cache = FormatterCache()

    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]

        func formatter(for style: UserDateFormat, withTime: Bool) -> DateFormatter? {
            let pattern: String
            switch (style, withTime) {
            case (.system, _):      return nil
            case (.us, false):      pattern = "MM/dd/yyyy"
            case (.us, true):       pattern = "MM/dd/yyyy, h:mm a"
            case (.european, false):pattern = "dd/MM/yyyy"
            case (.european, true): pattern = "dd/MM/yyyy, HH:mm"
            case (.iso, false):     pattern = "yyyy-MM-dd"
            case (.iso, true):      pattern = "yyyy-MM-dd HH:mm"
            }

            lock.lock()
            defer { lock.unlock() }
            if let existing = formatters[pattern] { return existing }
            let formatter = DateFormatter()
            formatter.dateFormat = pattern
            formatters[pattern] = formatter
            return formatter
        }
    }
}
