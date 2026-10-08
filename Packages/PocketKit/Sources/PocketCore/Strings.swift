// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// User-facing text built inside PocketCore, in the app's UI language. The app sets `language`
/// once at launch (iOS relaunches it when the language changes); tests default to Chinese.
public enum PocketStrings {
    nonisolated(unsafe) public static var language: UILanguage = .zhHans

    static func t(_ zh: String, _ en: String) -> String { language == .en ? en : zh }

    static func delivered() -> String { t("已送达", "Delivered") }
    static func deliveredNotLogged() -> String { t("已送达，记录未保存", "Delivered, not saved in the log") }
    static func spoken() -> String { t("已播报", "Spoken") }
    static func partlySpoken() -> String { t("只播了一部分", "Partly spoken") }
    static func taskDone() -> String { t("任务已完成", "Done") }
    static func steps(_ n: Int) -> String { t("\(n) 步", n == 1 ? "1 step" : "\(n) steps") }
    static func seconds(_ s: Int) -> String { t("\(s) 秒", "\(s) s") }
    static func minutes(_ m: Int) -> String { t("\(m) 分", "\(m) min") }
    static func today(_ hm: String) -> String { t("今天 ", "Today ") + hm }
    static func yesterday(_ hm: String) -> String { t("昨天 ", "Yesterday ") + hm }

    static func monthDay(_ month: Int, _ day: Int, _ hm: String) -> String {
        t("\(month)月\(day)日 ", "\(monthNames[max(0, min(11, month - 1))]) \(day), ") + hm
    }

    static func yearMonthDay(_ year: Int, _ month: Int, _ day: Int, _ hm: String) -> String {
        t("\(year)年\(month)月\(day)日 ", "\(monthNames[max(0, min(11, month - 1))]) \(day), \(year), ") + hm
    }

    static func fileTooLarge(limitMB: String?) -> String {
        guard let limitMB else { return t("文件太大", "File too large") }
        return t("文件太大（上限 \(limitMB) MB）", "File too large (limit \(limitMB) MB)")
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
