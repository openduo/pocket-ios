# Sight on the phone

When the room's perception service can see, it asks the room's capture edge for a camera. The app
answers that ask while ambient mode holds the room's capture seat: by itself when the phone
stands, and when the user turns the camera on while the closed phone is in a hand. Everything else about the room (listening, speaking, push, the Passport) is the same
with or without sight.

## The connection

The app opens `/live` with `media=1`: it speaks the binary framing below. The channel confirms
with `media` on its first `meta`. Without that answer the connection runs as before (one Opus
packet per binary frame) and has no camera; a camera ask on it is declined with
`unframed_channel`, and the phone says the channel is too old. An answer the app did not offer means the two ends disagree: the app
reconnects without `media`, and every later connection of the process does the same.

On a framed connection every binary frame starts with a kind byte. `0x01` is one Opus packet.
`0x02` is one H.264 access unit (Annex B) behind a header: flags (key frame, rate config
present), `seq` (u32), `at` (u64, ms since the epoch), then the configs, all little-endian. A key
frame carries the decoder config (`width`, `height`, `view`) and the rate config (`fps`,
`bitrate`); a delta frame carries the rate config when the rate changed. Nothing binary leaves
before the first `meta`.

## What the room asks

The channel's `camera` frame carries the ask (`capture`: size and H.264 video with codec, rate
ceiling `fps`, floor `min_fps`, bitrate ceiling and key interval) or `null` to stop, with the
largest frame the channel accepts. Sight is video only: there are no stills to fall back to.
The same ask again on the connection keeps the running camera and gets a key frame; changed
values restart it. A `camera` or `key_frame` from a socket whose `meta` was not read is ignored.

| Rule | What the app does |
|---|---|
| Rate | The asked `fps` and `bitrate`. At the serious thermal state it drops to `min_fps`, with the bitrate scaled by the same ratio, and returns when the phone cools; the camera and the encoder change in place, without a key frame. A camera that cannot run as slow as the floor runs at its slowest |
| Busy uplink | A frame that arrives while bytes still wait to leave is skipped before it is encoded. The declared rate stays; the frame times show the gap |
| Numbering | `seq` counts every chunk of the connection, sent or not, and never restarts on it, across camera switches and restarts. Only the current camera run's chunks are numbered; a stopped run's late output is dropped |
| Capture time | Read once at each run's first frame, carried forward on the camera's clock, and at least the last sent `at` plus one |
| Key frames | A chunk too large for the channel's bound is not sent, and nothing but a key frame follows it. `key_frame` asks for one. A camera switch or a turn between landscape and upright starts a new encoder, whose first chunk is a key frame with the new `view` or the swapped size |
| `view` | `facing` for the outer front camera (the person in front of the screen), `room` for the rear camera |

When an asked camera does not run, or stops on its own, the app says why with
`camera_declined {reason}`, once per reason. A key frame sent ends the decline; a camera that
starts but has not sent one has not resumed. No decline goes out while the camera-permission
prompt is up, whatever else changes under it.

| State | `reason` |
|---|---|
| Open flat in a hand; tabletop with the rear cameras on the lying half | `posture` |
| Switched off | `user_off` |
| App in the background | `background` |
| Camera held by another app or a call (the camera stays open, and resumes with a key frame when the other app lets go) | `camera_taken` |
| The session failed to start or stopped with an error (tried again on the next change) | `camera_taken` |
| Thermal state critical, or the system stopped the camera under pressure (the camera stays open until the system lets go) | `thermal` |
| Camera access refused | `camera_denied` |
| The encoder does not take the asked codec at the asked size, either way round | `no_h264` |
| No camera of the needed kind | `no_camera` |
| No format at the asked size, either way round, and a rate in the ask's range | `no_format` |
| The encoder failed while running (tried again on the next change) | `encoder_failed` |

A camera stop from the channel may carry `reason`: the channel declined for the phone (for
`nonconforming`, its video broke the ask). The room shows it until the next ask; a reason the
app does not know is shown as it came.

## Which camera

| Posture | Sight | Camera |
|---|---|---|
| Half-folded, outer display facing the person (tent) | on by default | outer front camera, `view: facing` |
| Closed and sideways on a charging stand (MagSafe) | on by default | outer front camera, `view: facing` |
| Half-folded on a table (tabletop) | on by default | rear main camera, `view: room` |
| Closed in a hand (or an iPhone that does not fold) | off until turned on, for this ambient session | outer front camera by default (`view: facing`); the flip turns to the rear main camera (`view: room`), remembered on this phone |
| Open flat in a hand | not offered | none |

A closed phone held sideways looks like a stand to the screen; power tells them apart, since a
phone held sideways is rarely charging. When it is, the 摄像头 switch turns the camera off.

The inner (under-display) camera is never used: with the phone open it only sees the holder.
Center Stage is off, so the picture keeps the same field every turn. The picture is levelled with
the horizon by the system's rotation coordinator.

## In the room

- **摄像头** joins the control row (静音 · 摄像头 · 别说了 · …) wherever the camera is offered.
  Standing it is a switch remembered on this phone; in a hand it turns the camera on until ambient
  mode ends. Without camera access it opens Settings.
- In a hand, while the camera is on, a flip button beside the state line turns between the front
  and the rear camera. The rear camera's picture replaces the mark, so the user can aim it.
- While frames leave the phone the room status gains a green dot and 「摄像头已开」. The front
  camera's picture is never shown: it would only show the person to themselves. The system's own camera indicator stays on as well.
- Open flat in a hand, a room that can see shows one line: 「把手机半折立起来，多多就能看到房间」.
- A pause or a failure replaces the line with the reason: the app in the background (iOS gives no
  camera there), the camera held by another app, the thermal state at critical, the rear cameras
  on the half lying on the table, a camera that cannot take the ask, or the room not accepting the
  phone's video.

## Not decided yet

- Whether one step down to the floor is too coarse. Each run logs `sight_thermal` at start, on
  every thermal change and at stop (elapsed time, frames encoded and skipped, the declared and the
  achieved rate), and `sight_rate` at each change; finer steps would come from those measurements.

- Which interface orientation puts the rear cameras' half upright on the table (logged as
  `sight_posture` until confirmed on a device); until then the app assumes they are up.
