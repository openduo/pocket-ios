// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

package tsbridge

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// LiveHandler receives the `/live` socket's frames. Implemented on the Swift
// side; called on Go threads, one frame at a time, in arrival order.
type LiveHandler interface {
	OnLiveText(text string)
	OnLiveBinary(data []byte)
	OnLiveClosed(reason string)
}

// The app holds one `/live` connection per room. It carries the conversation
// events always; when ambient mode is on, the app says `hello` on it, which
// takes the room's capture seat, and Opus flows both ways. A socket cannot
// un-hello: leaving ambient mode closes it and opens a new one.
var (
	liveMu      sync.Mutex
	liveConn    *websocket.Conn
	liveHandler LiveHandler
	// liveGen counts opens and closes. A dial that finishes after a later
	// open or close is stale and its socket is dropped.
	liveGen uint64
	// liveWriteTimeout bounds one frame write. A write that cannot finish in
	// this time is on a dead path; the reader notices the close.
	liveWriteTimeout = 5 * time.Second
)

// SetLiveHandler installs the receiver for `/live` frames.
func SetLiveHandler(h LiveHandler) {
	liveMu.Lock()
	liveHandler = h
	liveMu.Unlock()
}

// ErrLiveUnauthorized is the prefix of LiveOpen's error when the channel
// answers the upgrade with 401: the device token is missing or revoked, and
// redialling cannot help.
const ErrLiveUnauthorized = "tsbridge: live unauthorized"

// LiveOpen dials the `/live` socket at path (for example "/live?since=1").
// headersJSON is a JSON object of header name to value sent with the upgrade
// request; the target's device token is added unless it names its own
// Authorization. An existing socket is dropped first, without a
// close report.
func LiveOpen(path, headersJSON string, timeoutMs int64) error {
	mu.Lock()
	c := client
	mu.Unlock()
	if c == nil {
		return errors.New("tsbridge: not started")
	}
	t := currentTarget()
	if t.Host == "" {
		return errors.New("tsbridge: no target host")
	}
	url := "ws" + strings.TrimPrefix(t.origin(), "http") + path
	header := http.Header{}
	if headersJSON != "" {
		var h map[string]string
		if err := json.Unmarshal([]byte(headersJSON), &h); err != nil {
			return fmt.Errorf("tsbridge: headers: %w", err)
		}
		for k, v := range h {
			header.Set(k, v)
		}
	}
	t.authorize(header)
	gen := liveDrop()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	conn, res, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		HTTPClient: &http.Client{Transport: c.Transport},
		HTTPHeader: header,
	})
	if err != nil {
		if res != nil && res.StatusCode == http.StatusUnauthorized {
			return fmt.Errorf("%s: %w", ErrLiveUnauthorized, err)
		}
		return err
	}
	// Channel frames carry whole answers; the library default read limit is
	// far below that. The channel caps its own frames at 1 MiB (`maxPayload`).
	conn.SetReadLimit(1 << 20)
	liveMu.Lock()
	if liveGen != gen {
		liveMu.Unlock()
		conn.CloseNow()
		return errors.New("tsbridge: live socket closed while dialling")
	}
	liveConn = conn
	h := liveHandler
	liveMu.Unlock()
	go liveReadLoop(conn, h)
	return nil
}

func liveReadLoop(c *websocket.Conn, h LiveHandler) {
	for {
		typ, data, err := c.Read(context.Background())
		if err != nil {
			liveMu.Lock()
			current := liveConn == c
			if current {
				liveConn = nil
			}
			liveMu.Unlock()
			// A socket that LiveClose or LiveOpen already let go of is not
			// reported: its close is ours, and reporting it would make the app
			// reopen a socket it has just replaced.
			if current && h != nil {
				reason := err.Error()
				if s := websocket.CloseStatus(err); s != -1 {
					reason = "close " + s.String() + ": " + reason
				}
				h.OnLiveClosed(reason)
			}
			return
		}
		if h == nil {
			continue
		}
		if typ == websocket.MessageBinary {
			h.OnLiveBinary(data)
		} else {
			h.OnLiveText(string(data))
		}
	}
}

func liveWrite(typ websocket.MessageType, data []byte) error {
	liveMu.Lock()
	c := liveConn
	liveMu.Unlock()
	if c == nil {
		return errors.New("tsbridge: live socket not open")
	}
	ctx, cancel := context.WithTimeout(context.Background(), liveWriteTimeout)
	defer cancel()
	return c.Write(ctx, typ, data)
}

// LiveSendText sends one JSON text frame.
func LiveSendText(text string) error { return liveWrite(websocket.MessageText, []byte(text)) }

// LiveSendBinary sends one binary frame (one Opus packet).
func LiveSendBinary(data []byte) error { return liveWrite(websocket.MessageBinary, data) }

// LiveSendBinaries sends several binary frames, one per packet, in one call
// from the app: `framed` is each packet preceded by its length as a big-endian
// uint16 (an Opus packet is at most 1275 bytes). It stops at the first failed
// write.
func LiveSendBinaries(framed []byte) error {
	for len(framed) > 0 {
		if len(framed) < 2 {
			return errors.New("tsbridge: truncated packet length")
		}
		n := int(binary.BigEndian.Uint16(framed))
		framed = framed[2:]
		if n > len(framed) {
			return errors.New("tsbridge: truncated packet")
		}
		if err := liveWrite(websocket.MessageBinary, framed[:n]); err != nil {
			return err
		}
		framed = framed[n:]
	}
	return nil
}

// LiveIsOpen reports whether a socket is held. After a suspension it may be
// stale; LivePing tells.
func LiveIsOpen() bool {
	liveMu.Lock()
	defer liveMu.Unlock()
	return liveConn != nil
}

// LivePing sends a WebSocket ping and waits for the pong.
func LivePing(timeoutMs int64) error {
	liveMu.Lock()
	c := liveConn
	liveMu.Unlock()
	if c == nil {
		return errors.New("tsbridge: live socket not open")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	return c.Ping(ctx)
}

// LiveClose drops the socket without the closing handshake: the dropped
// socket has usually sat through a suspension, and a graceful Close would
// wait up to 5 s + 5 s (coder/websocket) for a peer that is gone. The channel
// releases the capture seat when the TCP stream ends.
func LiveClose() { liveDrop() }

// liveDrop closes the held socket, invalidates any dial in flight and
// returns the new generation.
func liveDrop() uint64 {
	liveMu.Lock()
	liveGen++
	gen := liveGen
	c := liveConn
	liveConn = nil
	liveMu.Unlock()
	if c != nil {
		c.CloseNow()
	}
	return gen
}
