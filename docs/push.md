# Push

多多随身 learns of 多多's messages only while it runs: in front, in ambient mode, or in the short
wake iOS gives it for a Passport press or a Background App Refresh. While it runs, a message that
arrives with the app not in front becomes a local notification (`AnswerNotice`). Push covers the
rest: the channel sends each of 多多's answers to a paired phone that has no open connection.

## Who sees what

```
app launch, pairing, background refresh
  app ──(APNs device token, environment)──▶ relay /v1/grant ──▶ grant (sealed by the relay)
  app ──(grant, its own 32-byte key)──▶ its channel  PUT /api/push  (over the tailnet)

an answer row, the phone not connected
  channel: AES-256-GCM seal {room, seq, message_ids, text}, padded to one size
  channel ──(grant, sealed, HMAC id, HMAC thread)──▶ relay /v1/push ──▶ APNs ──▶ phone
  DuoduoPush (notification service extension): open with the key, show the text
```

- The relay (`https://pocket-push.openduo.app`, source in `openduo/pocket-push`) holds the app's
  APNs key and nothing else. It sees the phone's APNs address, the time, and a sealed message of
  one fixed size; it cannot read text, room or message ids.
- The key is made on the phone, kept in the Keychain under the app group (readable after first
  unlock, this device only), and sent only to the phone's own channel.
- A grant lives seven days; the app renews it at every launch, Background App Refresh and pairing.
- A push the extension cannot open stays the placeholder 「多多发来一条消息」, without sound.

## One answer, one alert

The local notification and the push of one answer share an identifier,
`HMAC-SHA256(key, "pocket-push/answer\n" + sorted message ids + "\n" + trimmed text)`, used as
the request identifier and as `apns-collapse-id`; a push arriving after the local notification
replaces it. The extension keeps a small ledger in the app group: answers the app already
notified, the row cursor the user has read up to, and the rows already pushed. An answer already
notified, or at or below the read cursor, comes without sound. A row pushed a second time can only
be a replay, since the channel pushes each row once: it stays the silent placeholder. The relay's
envelope itself carries no sound, so a push the extension does not open never rings.

## Environments

Development-signed builds register with the APNs sandbox; App Store and TestFlight builds with
production. The app reads which from its provisioning profile.
