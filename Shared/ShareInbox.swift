// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Hand-off from the share extension to the app. The extension cannot reach the room (the tailnet
/// node lives in the app), so it copies what was shared into the App Group container and the app
/// moves it into the composer. One directory per share; `share.json` is written last and marks
/// the share complete, so the app never reads a half-copied one.
enum ShareInbox {
    /// URL the extension opens to bring the app forward with a share waiting.
    static let scheme = "duoduopocket"
    static let openURL = URL(string: "\(scheme)://share")!

    struct File: Codable {
        /// File name inside the share's directory.
        var file: String
        /// Name shown on the chip and sent to the channel.
        var name: String
        /// Uniform type identifier of the shared item.
        var type: String
    }

    struct Share: Codable {
        var text: String?
        var files: [File]
    }

    /// `PocketAppGroup` in both targets' Info.plist (`group.<bundle id of the app>`).
    static var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PocketAppGroup") as? String,
              let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return base.appendingPathComponent("ShareInbox", isDirectory: true)
    }

    private static let manifest = "share.json"

    /// A new, empty share directory (extension side).
    static func newShare() throws -> URL {
        guard let dir = directory else { throw CocoaError(.fileNoSuchFile) }
        let url = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Marks a share complete (extension side).
    static func commit(_ share: Share, in dir: URL) throws {
        try JSONEncoder().encode(share).write(to: dir.appendingPathComponent(manifest), options: .atomic)
    }

    /// Complete shares, oldest first (app side).
    static func pending() -> [(dir: URL, share: Share)] {
        guard let dir = directory,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        let dated = items.compactMap { url -> (URL, Date, Share)? in
            guard let d = try? Data(contentsOf: url.appendingPathComponent(manifest)),
                  let s = try? JSONDecoder().decode(Share.self, from: d) else { return nil }
            let at = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return (url, at, s)
        }
        return dated.sorted { $0.1 < $1.1 }.map { ($0.0, $0.2) }
    }

    static func remove(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }
}
