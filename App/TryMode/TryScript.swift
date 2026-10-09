// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// What DuoDuo says in 先体验. One turn per message, in order, whatever the user sent; after the
/// last turn it continues from the second (the first only introduces the mode). Content follows
/// the UI language. Every answer says or shows that it is prepared, never that it understood.
struct TryTurn {
    struct Tool {
        var name: String
        /// The tool input as the daemon serialises it; the app summarises it like a real step.
        var input: [String: String]
    }

    var tools: [Tool] = []
    /// Shown in the thread (Markdown).
    var text: String
    /// Sent to TTS and played in ambient mode; nil when it is the shown text.
    var spoken: String?
    /// Bundled audio of `spoken ?? text`, `<name>.m4a`.
    var audio: String
    /// A file DuoDuo sends after the answer: bundled resource name, shown name, MIME type.
    var file: (resource: String, name: String, mime: String)?
}

enum TryScript {
    static var en: Bool { PocketEngine.uiLanguage == .en }
    private static func L(_ zh: String, _ en: String) -> String { Self.en ? en : zh }

    static var turns: [TryTurn] {
        [
            TryTurn(text: L("你好，我是多多。现在是体验模式：我的回复是事先准备好的，不会真正理解你说的话。连上你自己部署的多多以后，对话才是真的。你可以继续发消息、按住说话、发图片，看看各个功能。",
                            "Hi, I'm DuoDuo. This is try-it mode: my replies are prepared in advance and don't understand what you say. Once you connect your own DuoDuo, the conversation is real. Keep sending messages, hold to talk or attach a photo to see how things work."),
                    audio: L("try-zh-1", "try-en-1")),
            TryTurn(tools: [.init(name: "WebSearch", input: ["query": L("明天 天气", "tomorrow weather")]),
                            .init(name: "WebFetch", input: ["url": L("https://www.weather.com.cn", "https://www.weather.gov")])],
                    text: L("查好了。明天多云转小雨，15 到 22 度，下午三点以后可能下雨，出门记得带伞。",
                            "Done. Tomorrow is cloudy turning to light rain, 15 to 22 °C, likely rain after 3 pm. Take an umbrella."),
                    audio: L("try-zh-2", "try-en-2")),
            TryTurn(text: L("""
                    ## 本周安排

                    | 时间 | 事项 | 地点 |
                    |---|---|---|
                    | 周二 10:00 | 产品评审 | 3 号会议室 |
                    | 周四 15:00 | 给妈妈打电话 | — |
                    | 周五 16:00 | 提交测试版 | 线上 |

                    **要准备的：**
                    1. 评审前把演示视频剪好
                    2. 周五前确认隐私政策链接能打开
                    """, """
                    ## This week

                    | When | What | Where |
                    |---|---|---|
                    | Tue 10:00 | Product review | Room 3 |
                    | Thu 15:00 | Call Mom | — |
                    | Fri 16:00 | Submit the beta | Online |

                    **To prepare:**
                    1. Cut the demo video before the review
                    2. Check the privacy policy link opens before Friday
                    """),
                    spoken: L("这周有三件事：周二上午十点产品评审，周四下午三点给妈妈打电话，周五下午四点提交测试版。详细的表格我发在对话里了。",
                              "Three things this week: the product review Tuesday at ten, calling Mom Thursday at three, and submitting the beta Friday at four. The full table is in the chat."),
                    audio: L("try-zh-3", "try-en-3")),
            TryTurn(tools: [.init(name: "Write", input: ["file_path": L("本周笔记.md", "weekly-notes.md")])],
                    text: L("我把这周的笔记整理成了一个文件，发给你了。", "I put this week's notes into a file and sent it to you."),
                    audio: L("try-zh-4", "try-en-4"),
                    file: (L("try-notes-zh", "try-notes-en"), L("本周笔记.md", "weekly-notes.md"), "text/markdown")),
        ]
    }

    /// Spoken once when ambient mode starts listening.
    static var ambientHello: (text: String, audio: String) {
        (L("我在听。环境模式下，我会在合适的时候插话，比如听到要记的事就帮你记下来。",
           "I'm listening. In ambient mode I chime in when it helps, for example to note down something you'd want to remember."),
         L("try-zh-ambient", "try-en-ambient"))
    }

    /// The text of a voice note: try-it mode does not transcribe.
    static func voiceText(seconds: Double) -> String {
        L(String(format: "（语音 %.1f 秒，体验模式不识别内容）", seconds),
          String(format: "(Voice, %.1f s. Try-it mode does not transcribe.)", seconds))
    }
}
