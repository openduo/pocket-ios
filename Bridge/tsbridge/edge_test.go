// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

package tsbridge

import (
	"bytes"
	"context"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

type edgeRecorder struct {
	mu     sync.Mutex
	texts  []string
	bins   [][]byte
	closed []string
}

func (h *edgeRecorder) OnEdgeText(s string) { h.mu.Lock(); h.texts = append(h.texts, s); h.mu.Unlock() }
func (h *edgeRecorder) OnEdgeBinary(b []byte) {
	h.mu.Lock()
	h.bins = append(h.bins, append([]byte(nil), b...))
	h.mu.Unlock()
}
func (h *edgeRecorder) OnEdgeClosed(r string) {
	h.mu.Lock()
	h.closed = append(h.closed, r)
	h.mu.Unlock()
}

func (h *edgeRecorder) snapshot() ([]string, [][]byte, []string) {
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
func TestEdgeCarriesTextAndBinaryInOrder(t *testing.T) {
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
	h := &edgeRecorder{}
	SetEdgeHandler(h)
	t.Cleanup(func() { EdgeClose(); SetEdgeHandler(nil) })

	if err := EdgeOpen("/live?room=a", 2000); err != nil {
		t.Fatal(err)
	}
	if !EdgeIsOpen() {
		t.Fatal("edge not open")
	}
	if err := EdgeSendText(`{"type":"hello"}`); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		if err := EdgeSendBinary([]byte{byte(i), 0xff}); err != nil {
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

func TestEdgeServerCloseIsReportedWithCode(t *testing.T) {
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		c.Close(websocket.StatusPolicyViolation, "room required")
	}))
	h := &edgeRecorder{}
	SetEdgeHandler(h)
	t.Cleanup(func() { EdgeClose(); SetEdgeHandler(nil) })
	if err := EdgeOpen("/live?room=x", 2000); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { _, _, c := h.snapshot(); return len(c) == 1 })
	_, _, closed := h.snapshot()
	if !bytes.Contains([]byte(closed[0]), []byte("StatusPolicyViolation")) {
		t.Fatalf("close reason %q lacks the close code", closed[0])
	}
	if EdgeIsOpen() {
		t.Fatal("edge still open")
	}
	if err := EdgeSendBinary([]byte{1}); err == nil {
		t.Fatal("send on a closed edge succeeded")
	}
}

func TestEdgeExplicitCloseIsNotReported(t *testing.T) {
	silentPeer(t)
	h := &edgeRecorder{}
	SetEdgeHandler(h)
	t.Cleanup(func() { SetEdgeHandler(nil) })
	if err := EdgeOpen("/live?room=a", 2000); err != nil {
		t.Fatal(err)
	}
	EdgeClose()
	time.Sleep(200 * time.Millisecond)
	if _, _, c := h.snapshot(); len(c) != 0 {
		t.Fatalf("explicit close reported: %q", c)
	}
}

func TestEdgeCloseDuringDialDropsTheNewSocket(t *testing.T) {
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
	h := &edgeRecorder{}
	SetEdgeHandler(h)
	t.Cleanup(func() { EdgeClose(); SetEdgeHandler(nil) })
	done := make(chan error, 1)
	go func() { done <- EdgeOpen("/live?room=a", 2000) }()
	time.Sleep(100 * time.Millisecond)
	EdgeClose()
	close(release)
	if err := <-done; err == nil {
		t.Fatal("open succeeded after a close during the dial")
	}
	if EdgeIsOpen() {
		t.Fatal("a socket closed during its dial is held")
	}
}
