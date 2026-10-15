// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

package tsbridge

import (
	"bytes"
	"context"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

type liveRecorder struct {
	mu     sync.Mutex
	texts  []string
	bins   [][]byte
	closed []string
}

func (h *liveRecorder) OnLiveText(s string) { h.mu.Lock(); h.texts = append(h.texts, s); h.mu.Unlock() }
func (h *liveRecorder) OnLiveBinary(b []byte) {
	h.mu.Lock()
	h.bins = append(h.bins, append([]byte(nil), b...))
	h.mu.Unlock()
}
func (h *liveRecorder) OnLiveClosed(r string) {
	h.mu.Lock()
	h.closed = append(h.closed, r)
	h.mu.Unlock()
}

func (h *liveRecorder) snapshot() ([]string, [][]byte, []string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.texts...), append([][]byte(nil), h.bins...), append([]string(nil), h.closed...)
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not met in time")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// An echo peer: text frames come back as text, binary as binary, in order.
func TestLiveCarriesTextAndBinaryInOrder(t *testing.T) {
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		for {
			typ, data, err := c.Read(context.Background())
			if err != nil {
				return
			}
			if err := c.Write(context.Background(), typ, data); err != nil {
				return
			}
		}
	}))
	h := &liveRecorder{}
	SetLiveHandler(h)
	t.Cleanup(func() { LiveClose(); SetLiveHandler(nil) })

	if err := LiveOpen("/live?room=a", "", 2000); err != nil {
		t.Fatal(err)
	}
	if !LiveIsOpen() {
		t.Fatal("socket not open")
	}
	if err := LiveSendText(`{"type":"hello"}`); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		if err := LiveSendBinary([]byte{byte(i), 0xff}); err != nil {
			t.Fatal(err)
		}
	}
	waitFor(t, func() bool { _, b, _ := h.snapshot(); return len(b) == 5 })
	texts, bins, closed := h.snapshot()
	if len(texts) != 1 || texts[0] != `{"type":"hello"}` {
		t.Fatalf("texts = %q", texts)
	}
	for i, b := range bins {
		if !bytes.Equal(b, []byte{byte(i), 0xff}) {
			t.Fatalf("binary %d = %v", i, b)
		}
	}
	if len(closed) != 0 {
		t.Fatalf("closed = %q", closed)
	}
}

func TestLiveServerCloseIsReportedWithCode(t *testing.T) {
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		c.Close(websocket.StatusPolicyViolation, "room required")
	}))
	h := &liveRecorder{}
	SetLiveHandler(h)
	t.Cleanup(func() { LiveClose(); SetLiveHandler(nil) })
	if err := LiveOpen("/live?room=x", "", 2000); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { _, _, c := h.snapshot(); return len(c) == 1 })
	_, _, closed := h.snapshot()
	if !bytes.Contains([]byte(closed[0]), []byte("StatusPolicyViolation")) {
		t.Fatalf("close reason %q lacks the close code", closed[0])
	}
	if LiveIsOpen() {
		t.Fatal("socket still open")
	}
	if err := LiveSendBinary([]byte{1}); err == nil {
		t.Fatal("send on a closed socket succeeded")
	}
}

func TestLiveExplicitCloseIsNotReported(t *testing.T) {
	silentPeer(t)
	h := &liveRecorder{}
	SetLiveHandler(h)
	t.Cleanup(func() { SetLiveHandler(nil) })
	if err := LiveOpen("/live?room=a", "", 2000); err != nil {
		t.Fatal(err)
	}
	LiveClose()
	time.Sleep(200 * time.Millisecond)
	if _, _, c := h.snapshot(); len(c) != 0 {
		t.Fatalf("explicit close reported: %q", c)
	}
}

func TestLiveCloseDuringDialDropsTheNewSocket(t *testing.T) {
	release := make(chan struct{})
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-release
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		_, _, _ = c.Read(context.Background())
	}))
	h := &liveRecorder{}
	SetLiveHandler(h)
	t.Cleanup(func() { LiveClose(); SetLiveHandler(nil) })
	done := make(chan error, 1)
	go func() { done <- LiveOpen("/live?room=a", "", 2000) }()
	time.Sleep(100 * time.Millisecond)
	LiveClose()
	close(release)
	if err := <-done; err == nil {
		t.Fatal("open succeeded after a close during the dial")
	}
	if LiveIsOpen() {
		t.Fatal("a socket closed during its dial is held")
	}
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
	h := &liveRecorder{}
	SetLiveHandler(h)
	t.Cleanup(func() { LiveClose(); SetLiveHandler(nil) })

	if err := LiveOpen("/live?room=a", "", 2000); err != nil {
		t.Fatal(err)
	}
	t0 := time.Now()
	if err := LiveOpen("/live?room=a", "", 2000); err != nil {
		t.Fatal(err)
	}
	// A graceful close would wait seconds for the silent peer's close frame.
	if d := time.Since(t0); d > time.Second {
		t.Fatalf("reopen took %v", d)
	}
	time.Sleep(200 * time.Millisecond)
	if _, _, got := h.snapshot(); len(got) != 0 {
		t.Fatalf("replaced socket reported as closed: %q", got)
	}

	// The held socket closing on the server side is reported once.
	kill()
	waitFor(t, func() bool { _, _, c := h.snapshot(); return len(c) > 0 })
	if _, _, got := h.snapshot(); len(got) != 1 {
		t.Fatalf("closes = %q, want one", got)
	}
	if LiveIsOpen() {
		t.Fatal("socket still marked open")
	}
}

func TestLivePing(t *testing.T) {
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		// Reading answers the pings.
		_, _, _ = c.Read(context.Background())
	}))
	h := &liveRecorder{}
	SetLiveHandler(h)
	t.Cleanup(func() { LiveClose(); SetLiveHandler(nil) })
	if err := LivePing(500); err == nil {
		t.Fatal("ping without a socket succeeded")
	}
	if err := LiveOpen("/live?room=a", "", 2000); err != nil {
		t.Fatal(err)
	}
	if err := LivePing(2000); err != nil {
		t.Fatal(err)
	}
}

// The upgrade request carries the given headers (the device token).
func TestLiveOpenSendsHeaders(t *testing.T) {
	got := make(chan string, 1)
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got <- r.Header.Get("Authorization")
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		_, _, _ = c.Read(context.Background())
	}))
	t.Cleanup(func() { LiveClose() })
	if err := LiveOpen("/live", `{"Authorization":"Bearer t1"}`, 2000); err != nil {
		t.Fatal(err)
	}
	if a := <-got; a != "Bearer t1" {
		t.Fatalf("Authorization = %q", a)
	}
}

// A 401 on the upgrade is reported as unauthorized, so the app stops redialling.
func TestLiveOpenUnauthorized(t *testing.T) {
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
	}))
	err := LiveOpen("/live", "", 2000)
	if err == nil || !strings.HasPrefix(err.Error(), ErrLiveUnauthorized) {
		t.Fatalf("err = %v", err)
	}
}

// The channel's 4401 close is reported with its code.
func TestLiveCloseUnauthorizedCode(t *testing.T) {
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		c.Close(websocket.StatusCode(4401), "unauthorized")
	}))
	h := &liveRecorder{}
	SetLiveHandler(h)
	t.Cleanup(func() { LiveClose(); SetLiveHandler(nil) })
	if err := LiveOpen("/live", "", 2000); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { _, _, c := h.snapshot(); return len(c) == 1 })
	if _, _, c := h.snapshot(); !strings.Contains(c[0], "4401") {
		t.Fatalf("close reason %q lacks 4401", c[0])
	}
}

// A malformed header object fails before dialling.
func TestLiveOpenBadHeaders(t *testing.T) {
	silentPeer(t)
	if err := LiveOpen("/live", "{", 2000); err == nil {
		t.Fatal("bad headers accepted")
	}
}
