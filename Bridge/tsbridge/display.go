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

// FrameHandler receives the display socket's text frames and its close event.
// Implemented on the Swift side; called on Go threads.
type FrameHandler interface {
	OnText(text string)
	OnClosed(reason string)
}

var (
	wsMu      sync.Mutex
	wsConn    *websocket.Conn
	wsHandler FrameHandler
	// wsGen counts opens and closes. A dial that finishes after a later open
	// or close is stale and its socket is dropped.
	wsGen uint64
)

// SetHandler installs the receiver for display frames.
func SetHandler(h FrameHandler) {
	wsMu.Lock()
	wsHandler = h
	wsMu.Unlock()
}

// WSOpen dials the channel's display socket at path (for example
// "/live?room=x") and starts a reader. It never sends `hello`: the socket is
// display only and never takes the room's capture seat. An existing socket is
// closed first.
func WSOpen(path string, timeoutMs int64) error {
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
	gen := wsDrop()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPClient: &http.Client{Transport: c.Transport}})
	if err != nil {
		return err
	}
	// Channel frames carry whole answers; the library default read limit is
	// far below that. The channel caps its own frames at 1 MiB (`maxPayload`).
	conn.SetReadLimit(1 << 20)
	wsMu.Lock()
	if wsGen != gen {
		wsMu.Unlock()
		conn.CloseNow()
		return errors.New("tsbridge: display socket closed while dialling")
	}
	wsConn = conn
	h := wsHandler
	wsMu.Unlock()
	go readLoop(conn, h)
	return nil
}

func readLoop(c *websocket.Conn, h FrameHandler) {
	for {
		typ, data, err := c.Read(context.Background())
		if err != nil {
			wsMu.Lock()
			current := wsConn == c
			if current {
				wsConn = nil
			}
			wsMu.Unlock()
			// A socket that WSClose or WSOpen already let go of is not reported:
			// its close is ours, and reporting it would make the app reopen a
			// socket it has just replaced.
			if current && h != nil {
				h.OnClosed(err.Error())
			}
			return
		}
		if h != nil && typ == websocket.MessageText {
			h.OnText(string(data))
		}
	}
}

// WSIsOpen reports whether a socket is held. After a suspension it may be
// stale; WSPing tells.
func WSIsOpen() bool {
	wsMu.Lock()
	defer wsMu.Unlock()
	return wsConn != nil
}

// WSPing sends a WebSocket ping and waits for the pong.
func WSPing(timeoutMs int64) error {
	wsMu.Lock()
	c := wsConn
	wsMu.Unlock()
	if c == nil {
		return errors.New("tsbridge: socket not open")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	return c.Ping(ctx)
}

// WSClose closes the socket if one is open. It skips the closing handshake:
// the dropped socket has usually sat through a suspension, and a graceful
// Close would wait up to 5 s + 5 s (coder/websocket) for a peer that is gone.
func WSClose() { wsDrop() }

// wsDrop closes the held socket, invalidates any dial in flight and returns
// the new generation.
func wsDrop() uint64 {
	wsMu.Lock()
	wsGen++
	gen := wsGen
	c := wsConn
	wsConn = nil
	wsMu.Unlock()
	if c != nil {
		c.CloseNow()
	}
	return gen
}
