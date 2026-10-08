// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// One human line per tool step, by the rules of the Feishu channel's process card, so both
/// clients describe a step the same way.
///
/// The channel forwards `turn tool` frames with `label` = the raw tool name and `input_summary` =
/// the tool input as the daemon serialised it (`JSON.stringify`), or `label` = `<name> ✓` when the
/// tool returned. The app turns that into `<name> <summary>`, never raw JSON.
public enum ToolLine {
    /// Widest summary kept, in characters (Feishu `TOOL_LINE_MAX_CHARS`: the widest tool line that
    /// never wrapped on its compact card). Display only: the full input stays in the daemon.
    public static let maxChars = 34

    /// Input keys tried in order (Feishu `SUMMARY_KEYS`). `description` leads: Bash and Task carry
    /// a one-line statement of the step beside the raw command.
    public static let summaryKeys = ["description", "command", "file_path", "path", "pattern", "query", "url",
                                     "prompt", "text"]

    /// The suffix the channel appends to a tool name when the tool returned.
    public static let resultSuffix = " ✓"

    /// `mcp__<server>__<tool>` → `<tool>`; anything else as is (Feishu `displayToolName`).
    public static func displayName(_ toolName: String) -> String {
        let ns = toolName as NSString
        guard let m = mcpName.firstMatch(in: toolName, range: NSRange(location: 0, length: ns.length)) else {
            return toolName
        }
        return ns.substring(with: m.range(at: 1))
    }

    private static let mcpName = try! NSRegularExpression(pattern: "^mcp__[^_]+(?:_[^_]+)*__(.+)$", options: [.dotMatchesLineSeparators])

    /// Whitespace runs become one space; longer than `max` characters ends in "…" (Feishu
    /// `cutToRow`). Counts grapheme clusters, so a CJK character or an emoji is one.
    public static func cut(_ text: String, max: Int = maxChars) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flat.count > max else { return flat }
        return String(flat.prefix(max - 1)) + "…"
    }

    /// One-row summary of a serialised tool input (Feishu `summarizeToolInput`); nil when nothing
    /// fits. Not JSON: the text itself. A JSON object: the first non-empty string among
    /// `summaryKeys`, then `files[0]`, then the first string value in key order.
    public static func summarize(_ inputSummary: String?) -> String? {
        guard let raw = inputSummary, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return cut(raw)
        }
        if let s = value as? String { return nonEmpty(s).map { cut($0) } }
        guard let obj = value as? [String: Any] else { return nil }
        for key in summaryKeys {
            if let s = obj[key] as? String, let v = nonEmpty(s) { return cut(v) }
        }
        if let files = obj["files"] as? [Any], let first = files.first as? String, let v = nonEmpty(first) {
            return cut(v)
        }
        // JSONSerialization drops key order; the daemon's own order decides "first".
        for key in topLevelKeys(raw) {
            if let s = obj[key] as? String, let v = nonEmpty(s) { return cut(v) }
        }
        return nil
    }

    private static func nonEmpty(_ s: String) -> String? {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    /// Keys of the top-level JSON object in source order. Assumes valid JSON (already parsed).
    static func topLevelKeys(_ json: String) -> [String] {
        var keys: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var expectKey = false
        var current = ""
        for ch in json {
            if inString {
                if escaped {
                    escaped = false
                    current.append(ch)
                } else if ch == "\\" {
                    escaped = true
                    current.append(ch)
                } else if ch == "\"" {
                    inString = false
                    if depth == 1, expectKey {
                        // Unescape through the parser so keys like "a\"b" match the dictionary.
                        let quoted = "\"" + current + "\""
                        if let k = try? JSONSerialization.jsonObject(with: Data(quoted.utf8), options: [.fragmentsAllowed]) as? String {
                            keys.append(k)
                        }
                        expectKey = false
                    }
                } else {
                    current.append(ch)
                }
                continue
            }
            switch ch {
            case "\"":
                inString = true
                current = ""
            case "{", "[":
                depth += 1
                if depth == 1, ch == "{" { expectKey = true }
            case "}", "]":
                depth -= 1
            case ",":
                if depth == 1 { expectKey = true }
            default:
                break
            }
        }
        return keys
    }
}
