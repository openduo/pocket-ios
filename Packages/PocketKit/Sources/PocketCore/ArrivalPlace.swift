// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// A place the phone says the user arrived at: a map name and the district and city around it,
/// named on the phone. No coordinates.
public struct ArrivalPlace: Codable, Equatable, Sendable {
    public var name: String
    public var area: String
    public var arrived: Date

    public init(name: String, area: String, arrived: Date) {
        self.name = name
        self.area = area
        self.arrived = arrived
    }

    /// Same name and area, whatever the arrival time.
    public func isSamePlace(as other: ArrivalPlace) -> Bool { name == other.name && area == other.area }

    /// The area line from a geocoder's city and district: largest first and unseparated when
    /// either is CJK ("北京市朝阳区"), else smallest first with a comma ("Mission, San Francisco").
    public static func area(city: String?, district: String?) -> String {
        let parts = [city, district].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let unique = parts.reduce(into: [String]()) { out, s in if !out.contains(s) { out.append(s) } }
        if unique.contains(where: Self.hasCJK) { return unique.joined() }
        return unique.reversed().joined(separator: ", ")
    }

    private static func hasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }
}

/// One `X-Ambient-Place` header: the place being reported and the last one the channel accepted.
public struct PlaceReport: Equatable, Sendable {
    public static let header = "X-Ambient-Place"

    public let place: ArrivalPlace
    /// The previously reported place's name and area; nil on the first report.
    public let previous: (name: String, area: String)?
    /// The offset written into `arrived`.
    public let timeZone: TimeZone

    public init(place: ArrivalPlace, previous: (name: String, area: String)?, timeZone: TimeZone = .current) {
        self.place = place
        self.previous = previous
        self.timeZone = timeZone
    }

    public static func == (a: PlaceReport, b: PlaceReport) -> Bool {
        a.place == b.place && a.previous?.name == b.previous?.name && a.previous?.area == b.previous?.area
            && a.timeZone == b.timeZone
    }

    /// The JSON object before encoding.
    public var json: [String: Any] {
        var o: [String: Any] = ["name": place.name, "area": place.area, "arrived": Self.timestamp(place.arrived, timeZone)]
        if let p = previous { o["previous"] = ["name": p.name, "area": p.area] }
        return o
    }

    /// Percent-encoded UTF-8 JSON: every byte outside the URI unreserved set is escaped, so the
    /// value is ASCII and `decodeURIComponent` restores it.
    public var headerValue: String {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-._~")
        let s = String(decoding: data, as: UTF8.self)
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public var headers: [String: String] { [Self.header: headerValue] }

    /// ISO 8601 with an explicit offset (`+08:00`, also `+00:00` rather than `Z`).
    static func timestamp(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        return f.string(from: d)
    }
}

/// The app's arrival bookkeeping: `current`, the latest arrival, and `reported`, the last place
/// the channel accepted. A report is pending while they differ. Stored in UserDefaults so a
/// relaunch for a visit and a later message see the same state. Thread-safe.
public final class PlaceLedger: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    static let currentKey = "place.current"
    static let reportedKey = "place.reported"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var current: ArrivalPlace? { lock.withLock { load(Self.currentKey) } }
    public var reported: ArrivalPlace? { lock.withLock { load(Self.reportedKey) } }

    /// Records an arrival. The same name and area as the current place keeps the earlier arrival
    /// time. Returns whether the current place changed.
    @discardableResult
    public func arrived(_ place: ArrivalPlace) -> Bool {
        lock.withLock {
            if let cur: ArrivalPlace = load(Self.currentKey), cur.isSamePlace(as: place) { return false }
            store(place, Self.currentKey)
            return true
        }
    }

    /// The report to attach to the next request, or nil when the current place was reported.
    /// A previous place with the current's own name and area (left and came back) is left out.
    public func pending(timeZone: TimeZone = .current) -> PlaceReport? {
        lock.withLock {
            guard let cur: ArrivalPlace = load(Self.currentKey) else { return nil }
            let rep: ArrivalPlace? = load(Self.reportedKey)
            if rep == cur { return nil }
            let previous = rep.flatMap { $0.isSamePlace(as: cur) ? nil : (name: $0.name, area: $0.area) }
            return PlaceReport(place: cur, previous: previous, timeZone: timeZone)
        }
    }

    /// The outcome of a request that carried `report`. Only an accepted one moves `reported`, to
    /// the place that was sent; an older place accepted late does not replace a newer one.
    public func settle(_ report: PlaceReport?, accepted: Bool) {
        guard let report, accepted else { return }
        lock.withLock {
            if let rep: ArrivalPlace = load(Self.reportedKey), rep.arrived > report.place.arrived { return }
            store(report.place, Self.reportedKey)
        }
    }

    /// Forgets both places (the setting was turned off).
    public func clear() {
        lock.withLock {
            defaults.removeObject(forKey: Self.currentKey)
            defaults.removeObject(forKey: Self.reportedKey)
        }
    }

    private func load(_ key: String) -> ArrivalPlace? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ArrivalPlace.self, from: $0) }
    }

    private func store(_ p: ArrivalPlace, _ key: String) {
        if let d = try? JSONEncoder().encode(p) { defaults.set(d, forKey: key) }
    }
}
