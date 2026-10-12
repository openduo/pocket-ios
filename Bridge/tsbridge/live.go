// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

package tsbridge

import (
	"context"
	"errors"
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

// LiveOpen dials the `/live` socket at path (for example
// "/live?room=x&since=1"). An existing socket is dropped first, without a
// close report.
func LiveOpen(path string, timeoutMs int64) error {
	mu.Lock()
	c := client
	mu.Unlock()
	if c == nil {
		return errors.New("tsbridge: not started")
	}
	base := BaseURL()
	if base == "" {
		return errors.New("tsbridge: no target host")
	}
	url := "ws" + strings.TrimPrefix(base, "http") + path
	gen := liveDrop()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPClient: &http.Client{Transport: c.Transport}})
	if err != nil {
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
