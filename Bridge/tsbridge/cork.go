// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

package tsbridge

import (
	"net"
	"sync"
	"time"
)

// corkConn is the `/live` socket's connection under the WebSocket library.
// While held, writes collect in a buffer and go out in one write on release:
// a capture block's frames then leave as one TCP segment, so one WireGuard
// packet, instead of one per frame. The library writes each frame
// synchronously inside its Write, so a hold spans exactly the frames written
// between hold and release (and any control frame written meanwhile, in order).
type corkConn struct {
	net.Conn
	mu      sync.Mutex
	holding bool
	buf     []byte
	// writes counts writes to the connection beneath (tests).
	writes int
}

func (c *corkConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.holding {
		c.buf = append(c.buf, p...)
		return len(p), nil
	}
	c.writes++
	return c.Conn.Write(p)
}

func (c *corkConn) hold() {
	c.mu.Lock()
	c.holding = true
	c.mu.Unlock()
}

// release writes what was held, bounded like a frame write: the library's own
// write timeout ended with the frame writes.
func (c *corkConn) release() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.holding = false
	if len(c.buf) == 0 {
		return nil
	}
	data := c.buf
	c.buf = c.buf[:0]
	c.writes++
	c.Conn.SetWriteDeadline(time.Now().Add(liveWriteTimeout))
	defer c.Conn.SetWriteDeadline(time.Time{})
	_, err := c.Conn.Write(data)
	return err
}
