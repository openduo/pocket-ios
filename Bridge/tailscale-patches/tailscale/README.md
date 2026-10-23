# Tailscale patches

Two files of `tailscale.com` (version in `../../go.mod`) are replaced at build time by
`scripts/build-tsbridge.sh` through a Go `-overlay`. They are upstream copies under Tailscale's
BSD-3-Clause licence with the changes marked `pocket patch`. `UPSTREAM.sha256` holds the hashes of
the upstream files they were made from; the build stops when those no longer match.

| File | Change | Why |
|---|---|---|
| `net/netmon/netmon.go` | the route-socket pump stops on `ENOTCONN` instead of retrying every second | an app outside a Network Extension cannot read the route socket, so the retry woke the process once a second forever; the app reports link changes through `tsbridge.Rebind` |
| `wgengine/magicsock/magicsock.go` | no periodic STUN while the last netcheck found no UDP path | periodic STUN keeps UDP NAT mappings fresh; without UDP each run fell back to a TLS dial to every DERP region every 20–26 s. Link changes, rebinds and DERP map changes still probe |

Both changes log one `pocket: ` line when they take effect; tsbridge forwards those lines to the
app log even when the tsnet log is off.

To upgrade Tailscale: bump `go.mod`, copy the two new upstream files here, re-apply the marked
changes, and regenerate `UPSTREAM.sha256` from the upstream files.
