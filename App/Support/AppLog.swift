// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import UIKit

/// Append-only JSONL event log, one file per launch, in Documents/logs (exported from the
/// Device page). Events are per press, per link change and per request, never per audio frame:
/// per-frame work in the background gets the app killed for CPU.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()
    private let queue = DispatchQueue(label: "pocket.log", qos: .utility)
    private var handle: FileHandle?
    let directory: URL
    let url: URL

    private init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        url = directory.appendingPathComponent("pocket-\(f.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func log(_ event: String, _ fields: [String: Any] = [:]) {
        var obj = fields
        obj["ev"] = event
        obj["t"] = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt,
                                               formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        queue.async { [handle] in
            guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
            handle?.write(d)
            handle?.write(Data([0x0a]))
        }
    }

    /// Log files plus the tsnet log, newest last, for the share sheet.
    func exportFiles(extra: [URL]) -> [URL] {
        queue.sync { try? handle?.synchronize() }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files + extra.filter { fm.fileExists(atPath: $0.path) }
    }
}

/// Process CPU time, for the per-press CPU share in the `press` log line.
enum CPUClock {
    /// User + system CPU seconds consumed by this process so far.
    static func processSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// Application state without blocking: the main-thread value is mirrored here on every
/// transition, so BLE-queue code can read it without a main-queue hop.
enum AppPhase {
    private static let lock = NSLock()
    private static var _value = "launching"

    static var value: String {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    static func set(_ v: String) {
        lock.lock(); _value = v; lock.unlock()
    }

    static var isActive: Bool { value == "active" }
}
