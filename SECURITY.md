# Security

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository (Security › Report a
vulnerability). Do not open a public issue for a vulnerability.

## Network model

- The app embeds a Tailscale node (tsnet, userspace networking). It joins the user's own tailnet
  after an interactive Tailscale login; no VPN profile is installed.
- Every connection dials out from the phone to the channel host on the tailnet (HTTPS or HTTP,
  per Settings, inside the WireGuard tunnel). Nothing listens on the phone.
- The channel host is reached on the tailnet only. Do not expose it with Tailscale Funnel or any
  other public ingress: the channel has no authentication of its own by design and relies on
  tailnet membership for access control.
- TODO: document the tailnet ACL that limits the phone node (`tag:pocket`) to the channel host's
  port.

## Passport link

- BLE with LE Secure Connections, bonding and numeric comparison. Both characteristics require an
  encrypted link (`docs/ble-protocol.md` §5).

## Data on the phone

- Settings (channel host, port, room) are in UserDefaults.
- The conversation cache, outbox and app logs are in the app container. Logs are in
  `Documents/logs` and visible in the Files app (`UIFileSharingEnabled`), so a user can share them.
- Tailscale node state is in `Library/Application Support/tsnet`. Settings › 退出登录 logs the node
  out.
- Audio: a phone voice note waiting to be sent is kept in the outbox (Opus packets) until it is
  uploaded or cancelled. Passport presses and ambient audio are streamed and not stored.
