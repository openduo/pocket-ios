// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// A typed reply that quotes one of DuoDuo's messages. The channel carries only text, so the quote
/// travels inside it: `<user-quote>` + the full quoted text + `</user-quote>`, a newline, then the
/// user's text. The pocket room's notes tell DuoDuo what the tag means.
///
/// The quote is never cut. A literal tag inside the quoted text is escaped (`<` → `&lt;`) so it
/// cannot close the quote early; `split` reverses it.
public enum UserQuote {
    public static let open = "<user-quote>"
    public static let close = "</user-quote>"
    private static let escapes = [(open, "&lt;user-quote>"), (close, "&lt;/user-quote>")]

    public static func compose(quote: String, text: String) -> String {
        var q = quote
        for (tag, escaped) in escapes { q = q.replacingOccurrences(of: tag, with: escaped) }
        return open + q + close + "\n" + text
    }

    /// The quote and the user's own text, or nil quote when the message does not start with one.
    public static func split(_ message: String) -> (quote: String?, text: String) {
        guard message.hasPrefix(open), let end = message.range(of: close) else { return (nil, message) }
        var q = String(message[message.index(message.startIndex, offsetBy: open.count)..<end.lowerBound])
        for (tag, escaped) in escapes { q = q.replacingOccurrences(of: escaped, with: tag) }
        var rest = message[end.upperBound...]
        if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        return (q, String(rest))
    }
}
