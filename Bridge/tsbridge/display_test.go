// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

package tsbridge

import (
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

type recordingHandler struct {
	mu     sync.Mutex
	closed []string
}

func (h *recordingHandler) OnText(string) {}

func (h *recordingHandler) OnClosed(reason string) {
	h.mu.Lock()
	h.closed = append(h.closed, reason)
	h.mu.Unlock()
}

func (h *recordingHandler) closes() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.closed...)
}

// A peer that accepts and then never reads, like a channel socket after the
// phone sat through a suspension. kill closes the server side of every socket.
func silentPeer(t *testing.T) (kill func()) {
	var mu sync.Mutex
	var conns []*websocket.Conn
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		mu.Lock()
		conns = append(conns, c)
		mu.Unlock()
		<-r.Context().Done()
	}))
	return func() {
		mu.Lock()
		defer mu.Unlock()
		for _, c := range conns {
			c.CloseNow()
		}
	}
}

func TestReplacingTheSocketIsQuickAndNotReported(t *testing.T) {
	kill := silentPeer(t)
	h := &recordingHandler{}
	SetHandler(h)
	t.Cleanup(func() { WSClose(); SetHandler(nil) })

	if err := WSOpen("/live?room=a", 2000); err != nil {
		t.Fatal(err)
	}
	t0 := time.Now()
	if err := WSOpen("/live?room=a", 2000); err != nil {
		t.Fatal(err)
	}
	// A graceful close would wait seconds for the silent peer's close frame.
	if d := time.Since(t0); d > time.Second {
		t.Fatalf("reopen took %v", d)
	}
	time.Sleep(200 * time.Millisecond)
	if got := h.closes(); len(got) != 0 {
		t.Fatalf("replaced socket reported as closed: %q", got)
	}

	// The live socket closing on the server side is reported once.
	kill()
	deadline := time.Now().Add(2 * time.Second)
	for len(h.closes()) == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if got := h.closes(); len(got) != 1 {
		t.Fatalf("closes = %q, want one", got)
	}
	if WSIsOpen() {
		t.Fatal("socket still marked open")
	}
}

func TestExplicitCloseIsNotReported(t *testing.T) {
	silentPeer(t)
	h := &recordingHandler{}
	SetHandler(h)
	t.Cleanup(func() { SetHandler(nil) })

	if err := WSOpen("/live?room=a", 2000); err != nil {
		t.Fatal(err)
	}
	t0 := time.Now()
	WSClose()
	if d := time.Since(t0); d > time.Second {
		t.Fatalf("close took %v", d)
	}
	time.Sleep(200 * time.Millisecond)
	if got := h.closes(); len(got) != 0 {
		t.Fatalf("explicit close reported: %q", got)
	}
}
