// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Finds, in the room log, the answer that ends a wait for one or more notes.
///
/// Pocket is one conversation: the reply to a waiting note is the first answer that arrived after
/// the note was sent, whatever `utt_id` it carries. The brain folds notes sent while it works into
/// the running turn and answers under the earliest note's `utt_id`, so the answer's `utt_id`
/// cannot be required to match (docs/ble-protocol.md §8).
///
/// The log is in arrival order. A note is sent at its typed row (the non-answer row carrying its
/// `utt_id`); an answer row after the earliest such row is the reply. An answer row naming one of
/// the notes counts too, so a note whose typed row lies on the previous day still finds it. An
/// answer logged before every note's typed row arrived before the notes were sent and never counts.
public enum LogCorrelation {
    /// Index of the first answer row after any of `notes` was sent, or nil when none is logged yet.
    public static func firstAnswerIndex<Row>(after notes: Set<String>, in rows: [Row], uttID: (Row) -> String?,
                                             isAnswer: (Row) -> Bool) -> Int? {
        guard !notes.isEmpty else { return nil }
        var sent = false
        for (i, row) in rows.enumerated() {
            let id = uttID(row)
            if isAnswer(row) {
                if sent || id.map(notes.contains) == true { return i }
            } else if let id, notes.contains(id) {
                sent = true
            }
        }
        return nil
    }

    public static func firstAnswerIndex(after notes: Set<String>, in entries: [ImlogEntry]) -> Int? {
        firstAnswerIndex(after: notes, in: entries, uttID: \.utt_id, isAnswer: \.isAnswer)
    }
}
