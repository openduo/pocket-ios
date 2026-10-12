// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Which side must be upgraded when this app and its channel no longer speak the same client API.
public enum UpgradeNotice: Equatable, Sendable {
    /// The channel answered 410 `update_required`: this app is too old.
    case appUpdate
    /// The channel predates the client API this app needs.
    case channelUpgrade

    /// The notice a `POST /api/messages` response carries, if any. A 404 means the channel has
    /// no messages route yet.
    public static func of(status: Int, error: String) -> UpgradeNotice? {
        switch status {
        case 410 where error == "update_required": .appUpdate
        case 404: .channelUpgrade
        default: nil
        }
    }

    /// The notice a `ready` carries: an absent or lower `api` means the channel is too old.
    public static func of(_ ready: LiveEvent.Ready) -> UpgradeNotice? {
        guard let api = ready.api, api >= PocketConstants.clientAPIMajor else { return .channelUpgrade }
        return nil
    }
}
