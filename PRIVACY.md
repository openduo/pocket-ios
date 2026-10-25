# Privacy Policy — DuoDuo Pocket (多多随身)

Effective 2026-10-25.

DuoDuo Pocket is a client for a DuoDuo assistant that **you run yourself**. OpenDuo runs one
service for this app, the push relay described below, and it cannot read your messages.

## What the app sends, and where

| Data | Where it goes | Why |
|---|---|---|
| Messages, voice recordings, photos and files you send | Only to the DuoDuo channel you configure, over your own Tailscale network | So your assistant can answer |
| Microphone audio in ambient mode | Only to that channel, while ambient mode is on | Ambient conversation |
| The name of a place you arrived at (for example a building and its district and city), the arrival time, and the previous such place | Only to that channel, with your next message or ambient session, and only if you turned on 让多多知道我到了哪 (Let DuoDuo know where I've arrived) in Settings; off by default. Coordinates are never sent | So your assistant knows roughly where you are |
| Tailscale sign-in and device identity | Tailscale, under Tailscale's own privacy policy | To join your tailnet |
| The phone's Apple push address (device token) | The OpenDuo push relay, and through it Apple Push Notification service, only when your channel offers push | So DuoDuo's answers reach you while the app is not running |

The app has no analytics, advertising, tracking or crash reporting, and no OpenDuo account.
The embedded Tailscale node is configured not to upload its logs.

## Push notifications

While the app is not running, your channel sends DuoDuo's answers to the phone through the OpenDuo
push relay (pocket-push.openduo.app), which holds the app's Apple push key. Before anything leaves
your channel it is encrypted with a key made on your phone and shared only with your channel.

- At registration the relay sees the phone's IP address and its Apple push address.
- For each push it sees your channel's IP address, the time, and an encrypted message of one fixed
  size. It cannot read the text, your room or which messages it answers.
- It stores nothing and keeps no request logs. Apple delivers the notification under its own
  privacy policy.
- Your channel's operator can turn push off; unpairing the phone on the channel stops it.

## What stays on the phone

The conversation cache, settings, Passport pairing and diagnostic logs stay on the device. Logs
leave it only when you share them yourself from Settings. Deleting the app deletes all of it.

In try-it mode (先体验) nothing is sent anywhere; its messages, recordings and files are deleted
when you exit.

## Permissions

- Microphone: hold-to-talk and ambient mode.
- Bluetooth: the optional Passport accessory.
- Camera and Photos: only when you attach a picture.
- Location, while using the app: centring the map when you send a location in the chat.
- Location, always: only for 让多多知道我到了哪 (off by default). iOS tells the app when you have
  arrived somewhere and stayed; the phone turns the spot into a place name with Apple's map
  service and keeps only that name, its area and the arrival time. Turning the setting off stops
  it and deletes the stored places.
- Local network: the Tailscale node looks for a direct path to your own devices.
- Notifications, asked when you first turn on ambient mode or open the app: DuoDuo's answers that
  arrive while the app is not in front, and one local notice when a call or other audio stopped
  ambient mode while the app was in the background.

## Your server

What your DuoDuo deployment stores is under your control and its configuration; this app does not
change it.

## Contact

Questions: <https://github.com/openduo/pocket-ios/issues>

---

# 隐私政策 — 多多随身

生效日期：2026-10-25。

多多随身是**你自己部署的**多多助手的客户端。OpenDuo 只为这个 App 运营一项服务，即下面说明的推送中转，它读不到你的消息。

## App 发送什么、发到哪里

| 数据 | 去向 | 用途 |
|---|---|---|
| 你发送的消息、录音、照片和文件 | 只发到你设置的多多频道，经过你自己的 Tailscale 网络 | 让你的助手回答 |
| 环境模式下的麦克风声音 | 只在环境模式开启时发到这个频道 | 环境模式对话 |
| 你到达的地点名称（例如一栋楼和它所在的区、城市）、到达时间，以及上一个这样的地点 | 只在你在设置里打开「让多多知道我到了哪」后（默认关闭），随你的下一条消息或环境模式会话发到这个频道；从不发送坐标 | 让你的助手大致知道你在哪 |
| Tailscale 登录和设备身份 | Tailscale，适用 Tailscale 自己的隐私政策 | 加入你的 tailnet |
| 手机的 Apple 推送地址（device token） | OpenDuo 推送中转，再经它到 Apple 推送服务；只在你的频道提供推送时 | App 没在运行时也能收到多多的回答 |

App 没有统计、广告、追踪和崩溃上报，也没有 OpenDuo 账号。内置的 Tailscale 节点设置为不上传日志。

## 推送通知

App 没在运行时，你的频道经 OpenDuo 推送中转（pocket-push.openduo.app）把多多的回答发到手机，中转持有这个 App 的 Apple 推送密钥。内容离开频道之前，已用手机生成、只与你的频道共享的密钥加密。

- 登记推送时，中转能看到手机的 IP 地址和它的 Apple 推送地址。
- 每次推送，中转能看到你频道的 IP 地址、时间，以及一段固定长度的密文；它读不到文字、房间，也不知道回答的是哪条消息。
- 中转不保存任何数据，也不记录请求日志。通知由 Apple 投递，适用 Apple 自己的隐私政策。
- 频道的运营者可以关闭推送；在频道上取消这部手机的配对，推送随即停止。

## 留在手机上的数据

对话缓存、设置、Passport 配对和诊断日志都留在手机上。只有你在设置里主动分享时，日志才会离开手机。删除 App 会删除全部数据。

体验模式（先体验）不向任何地方发送数据，退出时删除其中的消息、录音和文件。

## 权限

- 麦克风：按住说话和环境模式。
- 蓝牙：可选配件 Passport。
- 相机和照片：只在你添加图片时使用。
- 使用 App 期间的定位：在对话中发送位置时把地图移到你所在的地方。
- 始终定位：只用于「让多多知道我到了哪」（默认关闭）。iOS 在你到达某处并停留时通知 App；手机用 Apple 的地图服务把这个位置换成地名，只保存地名、所在区域和到达时间。关闭这个设置会停止使用定位并删除保存的地点。
- 本地网络：Tailscale 节点寻找到你自己设备的直连路径。
- 通知：第一次打开环境模式或打开 App 时请求。用于 App 不在前台时收到的多多回答，以及 App 在后台、来电或其他声音中断了环境模式时的一条本地通知。

## 你的服务器

你的多多部署保存什么，由你和你的配置决定，这个 App 不会改变它。

## 联系

问题反馈：<https://github.com/openduo/pocket-ios/issues>
