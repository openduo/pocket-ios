// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import MetricKit

/// Keeps the system's daily energy and performance reports (MetricKit) beside the app log, so
/// an exported log shows how the app fared on the phone over the past days. Temporary: it is
/// removed once the energy work it measures is done (docs/design/native-app.md, Backlog).
final class MetricsLog: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricsLog()

    /// Subscribes; the system delivers past reports at most once a day.
    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads { save(p.jsonRepresentation(), "metrics", p.timeStampEnd) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { save(p.jsonRepresentation(), "diagnostics", p.timeStampEnd) }
    }

    private func save(_ json: Data, _ kind: String, _ end: Date) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = AppLog.shared.directory.appendingPathComponent("\(kind)-\(f.string(from: end)).json")
        try? json.write(to: url, options: .atomic)
        AppLog.shared.log("metrickit", ["kind": kind, "file": url.lastPathComponent])
    }
}
