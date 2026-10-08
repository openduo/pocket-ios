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

// EdgeHandler receives the ambient edge socket's frames. Implemented on the
// Swift side; called on Go threads, one frame at a time, in arrival order.
type EdgeHandler interface {
	OnEdgeText(text string)
	OnEdgeBinary(data []byte)
	OnEdgeClosed(reason string)
}

// The edge socket is a second `/live` connection that says `hello` and so
// takes the room's capture seat (native ambient mode). It is separate from the
// display socket because a socket cannot un-hello: closing this one releases
// the seat at once while the display socket keeps the conversation.
var (
	edgeMu      sync.Mutex
	edgeConn    *websocket.Conn
	edgeHandler EdgeHandler
	// edgeGen counts opens and closes. A dial that finishes after a later
	// open or close is stale and its socket is dropped.
	edgeGen uint64
	// edgeWriteTimeout bounds one frame write. A write that cannot finish in
	// this time is on a dead path; the reader notices the close.
	edgeWriteTimeout = 5 * time.Second
)

// SetEdgeHandler installs the receiver for edge frames.
func SetEdgeHandler(h EdgeHandler) {
	edgeMu.Lock()
	edgeHandler = h
	edgeMu.Unlock()
}

// EdgeOpen dials the edge socket at path (for example "/live?room=x"). An
// existing edge socket is dropped first.
func EdgeOpen(path string, timeoutMs int64) error {
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
	gen := edgeDrop()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPClient: &http.Client{Transport: c.Transport}})
	if err != nil {
		return err
	}
	// Same bound as the display socket: the channel's own `maxPayload`.
	conn.SetReadLimit(1 << 20)
	edgeMu.Lock()
	if edgeGen != gen {
		edgeMu.Unlock()
		conn.CloseNow()
		return errors.New("tsbridge: edge socket closed while dialling")
	}
	edgeConn = conn
	h := edgeHandler
	edgeMu.Unlock()
	go edgeReadLoop(conn, h)
	return nil
}

func edgeReadLoop(c *websocket.Conn, h EdgeHandler) {
	for {
		typ, data, err := c.Read(context.Background())
		if err != nil {
			edgeMu.Lock()
			current := edgeConn == c
			if current {
				edgeConn = nil
			}
			edgeMu.Unlock()
			// A socket EdgeClose or EdgeOpen already dropped is not reported.
			if current && h != nil {
				reason := err.Error()
				if s := websocket.CloseStatus(err); s != -1 {
					reason = "close " + s.String() + ": " + reason
				}
				h.OnEdgeClosed(reason)
			}
			return
		}
		if h == nil {
			continue
		}
		if typ == websocket.MessageBinary {
			h.OnEdgeBinary(data)
		} else {
			h.OnEdgeText(string(data))
		}
	}
}

func edgeWrite(typ websocket.MessageType, data []byte) error {
	edgeMu.Lock()
	c := edgeConn
	edgeMu.Unlock()
	if c == nil {
		return errors.New("tsbridge: edge socket not open")
	}
	ctx, cancel := context.WithTimeout(context.Background(), edgeWriteTimeout)
	defer cancel()
	return c.Write(ctx, typ, data)
}

// EdgeSendText sends one JSON text frame.
func EdgeSendText(text string) error { return edgeWrite(websocket.MessageText, []byte(text)) }

// EdgeSendBinary sends one binary frame (one Opus packet).
func EdgeSendBinary(data []byte) error { return edgeWrite(websocket.MessageBinary, data) }

// EdgeIsOpen reports whether an edge socket is held.
func EdgeIsOpen() bool {
	edgeMu.Lock()
	defer edgeMu.Unlock()
	return edgeConn != nil
}

// EdgeClose drops the edge socket without the closing handshake (same reason
// as WSClose). The channel releases the seat when the TCP stream ends.
func EdgeClose() { edgeDrop() }

// edgeDrop closes the held socket, invalidates any dial in flight and
// returns the new generation.
func edgeDrop() uint64 {
	edgeMu.Lock()
	edgeGen++
	gen := edgeGen
	c := edgeConn
	edgeConn = nil
	edgeMu.Unlock()
	if c != nil {
		c.CloseNow()
	}
	return gen
}
