# Pocket link contract (phone side)

The contract between 多多随身, the Passport firmware and the ambient channel, as this app
implements it. The Passport firmware implements the device side of sections 4–9; the channel
implements section 2. Change both ends together.

## 1. Audio

Opus, 16 kHz mono, 20 ms frames, complexity 0, VBR, DTX off while the button is held, FEC off.
One Opus packet is the unit on every hop: BLE AUDIO message, upload body, transcription request.

## 2. Voice-note upload

`POST /api/voice?room=<room>` on the channel.

- Headers: `Content-Type: application/vnd.ambient.opus-packets`, `X-Voice-Id: <uuid>` (generated
  by the app, idempotency key for retries), `X-Voice-Source: passport | phone`.
- Body: `[u16 little-endian length][opus packet bytes]` per packet, in capture order.
- 200: `{"voice_id", "text", "utt_id"}` once the transcript is accepted into the conversation.
- Errors (`{"voice_id", "error"}`): 422 `empty_transcript`, 502 `asr_failed`, 503
  `cerebellum_unavailable`, 400 `bad_body`. A repeated `X-Voice-Id` returns the first result and
  never sends the text twice.

## 3. Replies

The app learns answers from its display socket (`/live?room=…` without `hello`) and catches up
from the room log (`GET /api/state`, `GET /api/imlog`). Answers are `answer_final` /
`duoduo_said` rows. Correlation and the reply wait are in sections 8 and 9.

## 4. GATT

| Item | UUID | Properties |
|---|---|---|
| Primary service | `8bd90001-86c5-454b-b65b-3f16cffb662f` | advertised in the primary advertisement (iOS background scans filter by it) |
| TX (device → phone) | `8bd90002-86c5-454b-b65b-3f16cffb662f` | notify, encryption required |
| RX (phone → device) | `8bd90003-86c5-454b-b65b-3f16cffb662f` | write without response, encryption required |

Source of truth in code: `PocketConstants` in `Packages/PocketKit`.

## 5. Security

LE Secure Connections with bonding and numeric comparison. The phone side has no pairing code:
the first subscribe to the encrypted TX characteristic makes iOS start pairing and show the
number; the user confirms it on the phone and with OK on the Passport. Re-pairing: forget the
device in iOS Settings › Bluetooth, re-pair on the Passport, then reopen the app's Device page.

## 6. PDU

`[type u8][flags u8][len u16 LE][payload]`, one PDU per ATT value. `flags bit0` = more fragments
follow. A message longer than one ATT value is split into consecutive PDUs of the same type.
Fragments of one message are consecutive: any other PDU arriving between them drops the partial
message. A PDU whose `len` differs from the value length is dropped.

- Fragment size: ATT value size minus 4. The phone uses
  `maximumWriteValueLength(for: .withoutResponse)` at send time; the device uses its
  negotiated MTU − 3.
- Max message size: **4096 bytes** in both directions (basis in `docs/constants.md`). A REPLY or RESULT text longer than that is cut at a character boundary
  with "…" for the device; the phone keeps the full text.

## 7. Messages

Device → phone:

| Type | Name | Payload |
|---|---|---|
| 0x01 | INFO | proto_major u8, proto_minor u8, firmware version (item 1), battery % u8, charging u8, preroll u8 |
| 0x02 | PRESS_START | press_id u16 |
| 0x03 | AUDIO | press_id u16, seq u16, one Opus packet |
| 0x04 | PRESS_END | press_id u16, packet count u16 |
| 0x05 | STATUS | battery % u8, charging u8 (on change) |
| 0x06 | KEEPALIVE | press_id u16 (only while waiting for a reply) |

Phone → device:

| Type | Name | Payload |
|---|---|---|
| 0x81 | RESULT | press_id u16, code u8 (0 transcribed, 1 empty, 2 asr_failed, 3 send_failed, 4 not_connected_to_server), UTF-8 text (transcript when code 0) |
| 0x82 | REPLY | reply_id u32, final u8, UTF-8 text (replace semantics: the device shows the latest full text for the id) |
| 0x83 | REPLY_DONE | reply_id u32 (the device stops its keepalive) |
| 0x84 | APP_STATE | state u8 (0 ok, 1 server unreachable, 2 protocol major mismatch), then language u8 (protocol 1.2, item 9) |
| 0x85 | WORK | phase u8, optional UTF-8 label (protocol 1.1) |

All integers are little-endian. INFO carries the protocol version: a different major is refused
with a visible error on both ends; minors are additive. The app speaks 1.2. A 1.0 device ignores
WORK as an unknown type; a 1.0 or 1.1 device ignores the language byte after APP_STATE's state
(its parser ignores bytes after the fixed fields). The device owns the tap threshold; the app treats a press of any length as
speech.

Payload details:

1. **INFO firmware version** is one length byte followed by the UTF-8 string (no NUL):
   `proto_major, proto_minor, fw_len, fw…, battery, charging, preroll`. Fields after `preroll`
   (later minors) are ignored.
2. **Charging** (INFO and STATUS): 0 no, 1 yes, 0xFF unknown. Any other value reads as unknown.
3. **AUDIO `seq`** starts at 0 for each press; a packet the device's link refused still consumes a
   seq, and PRESS_END's count is the number of seqs used. The phone counts the holes as gaps.
   `press_id` starts at a random value per device boot.
4. **APP_STATE 2** = protocol major mismatch; the device shows it.
5. **REPLY_DONE with `reply_id` 0** means "the phone stopped waiting without a reply" (the device
   stops its keepalive). The app sends it on `turn idle` without the answer, or when the display
   socket cannot be restored during a wait. Real reply ids are never 0.
6. **REPLY `reply_id`** comes from a per-phone counter: each new answer takes the last id plus
   one, but never less than the phone's current Unix time in seconds (skipping 0). The counter
   survives relaunches; the time floor keeps ids above every earlier id after a reinstall, which
   empties the counter (the Passport stores and alerts once per id, so a reused id would be shown
   silently and not stored). Ids are unique and increase in the order answers were sent; they are
   not consecutive. Partial texts of one utterance share the id (`final` 0); the answer ends
   with `final` 1 and REPLY_DONE. An answer sent again (link ready, or closing a wait with an
   answer the device already has) keeps the id it was first sent with.
7. **KEEPALIVE** is sent by the device every 5 s while waiting, until REPLY_DONE, a failed
   RESULT, the next press or link loss. There is no time cap on either end (section 9).
8. **WORK**: `phase u8` (0 idle, 1 received, 2 thinking, 3 tool), then an optional
   UTF-8 label (always empty in v1).
9. **APP_STATE language** (protocol 1.2): one byte after `state`, the phone app's UI language,
   so the Passport shows its own text in the same language. `0` = Simplified Chinese (zh-Hans),
   `1` = English (en). The app sends it in every APP_STATE: at link ready, on every reachability
   change, and once more with the current state whenever its UI language changes. The device
   applies it at once (redraws its current screen) and keeps it across reboots. A missing byte
   (a 1.0/1.1 phone) or an unknown value leaves the device's language unchanged; the device's
   default is zh-Hans. Text that comes from the brain (RESULT transcript, REPLY, WORK label) is
   shown as sent and is not translated.

## 8. Phone behaviour

- INFO when the phone subscribes on the current connection, and again whenever the device
  receives APP_STATE (Passport firmware behaviour). The first covers a bonded reconnect: the
  device used to restore the subscription with the bond and send INFO before iOS had rediscovered
  the characteristic, so INFO was lost. The second covers an app relaunch on a live connection
  (state restoration, reinstall): the subscription never changes, but the app always sends
  APP_STATE after link ready, so INFO follows. A different `proto_major` is refused: the app
  sends APP_STATE 2, the Device page shows the mismatch, and press messages are ignored.
- One press = one voice note. AUDIO without a preceding PRESS_START (app relaunched mid-press)
  starts the press implicitly. A link drop mid-press uploads what arrived.
- RESULT after every press: 0 transcribed (with text), 1 empty, 2 asr_failed, 3 send_failed,
  4 not_connected_to_server.
- APP_STATE on link ready, whenever channel reachability changes, and when the UI language
  changes (item 9 of section 7).
- Reply correlation: pocket is one conversation. `/api/voice` 200 returns `utt_id`, which marks
  when the note was sent. While a note waits, the first answer that arrives after it was sent is
  the reply, whatever `utt_id` the answer carries, and it ends every pending wait. The brain folds
  notes sent while it works into the running turn and answers them under the earliest note's
  `utt_id`, so requiring the waited note's id lost those answers (observed: three notes sent
  during one turn were all answered under the first note's `utt_id`; the Passport waited on the
  last and got REPLY_DONE 0).
  - Live: the first `answer_final` after the wait started. Partial text is not forwarded while a
    note waits: a delta may belong to an answer that began before the note.
  - Room log: the first answer row after the typed row of the earliest waiting note (the typed row
    carries the note's `utt_id`). An answer row naming a waiting note counts as well, for a typed
    row on the previous day.
  - An answer that arrived before the note was sent never counts, live or logged.
  - The same answer is sent once: live and log copies are matched by text and `utt_id` (a missing
    `utt_id` matches any). If the first answer after the note was already sent while nobody
    waited, it goes again under its first id to close the wait.
  - Without `utt_id` (KEEPALIVE adopted after a relaunch) the newest unsent answer is the reply.
    With no reply pending, every answer is forwarded.
- The brain can answer before the display socket is back after a wake (a 2.3 s answer against a
  3.2 s reconnect). That answer exists only in the room log, so the catch-up after every socket
  check (wait start, KEEPALIVE) is what delivers it.
- KEEPALIVE wakes the app while a reply is pending: it re-checks the display socket and catches up
  from the room log. KEEPALIVE received without a pending reply (after a relaunch) adopts the wait.

## 9. Reply wait and work status

| Event | Phone sends | Wait |
|---|---|---|
| Voice note accepted (RESULT 0) | WORK 1 | starts |
| Display socket `turn` frame, `phase` `thinking` / `tool` | WORK 2 / 3 | continues |
| Other `turn` phases (`received`, `speaking`, `done`) | nothing | continues |
| First answer after the note was sent (any `utt_id`), live or from the room log | REPLY final, REPLY_DONE id | ends (all pending) |
| `turn` `phase: "idle"` with no answer since the note | WORK 0, REPLY_DONE 0 | ends |
| Display socket cannot be reopened (dial or tsnet failure) | APP_STATE 1 (on change), REPLY_DONE 0 | ends |
| PRESS_START of a new press | nothing (the device ended its wait itself) | ends |
| Answer after the wait ended | REPLY final, REPLY_DONE id (when linked) | — |

`turn` frames carry `utt_id: null`, so every `turn` frame of the app's room counts while a reply is
pending. There is no time limit on the wait; until the channel emits `turn idle`, a wait whose
answer never comes ends only through the display socket or a new press.
- Proactive answers: every answer the app receives is forwarded as REPLY
  final + REPLY_DONE, with or without a pending press, so the device can alert. The app receives
  answers live on the display socket (foreground, reply wait, ambient), from the room log when the
  link becomes ready (a BLE wake), and from Background App Refresh. Fully suspended, nothing
  arrives until the next wake. Without a pending press, partial REPLY texts (`final` 0) of a
  streaming answer precede the final one under the same id; a device that alerts should alert
  once per `reply_id`.
- When the link becomes ready the newest answer is sent only if the device was not handed it yet
  (it came while the link was down, possibly before a relaunch). Earlier builds re-sent the latest
  answer on every link-ready; with an alert on every REPLY that repeated the alert on each
  reconnect. The wire format is unchanged.
- Duplicates: an answer is forwarded once (text and `utt_id` fingerprint, see reply correlation).
  `reply.memory` also stores the newest answer and the newest final reply id handed to a ready
  link; a write without response lost in a link drop at that moment is not retried.
