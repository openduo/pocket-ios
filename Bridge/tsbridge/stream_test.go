// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

package tsbridge

import (
	"bytes"
	"net/http"
	"sync"
	"testing"
)

type chunks struct {
	mu  sync.Mutex
	got bytes.Buffer
	n   int
	on  func()
}

func (c *chunks) OnStreamData(data []byte) {
	c.mu.Lock()
	c.got.Write(data)
	c.n++
	on := c.on
	c.mu.Unlock()
	if on != nil {
		on()
	}
}

func TestStreamDeliversTheBodyAsItArrives(t *testing.T) {
	release := make(chan struct{})
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/speech" || r.Method != "POST" || r.Header.Get("Content-Type") != "application/json" {
			http.Error(w, "unexpected", 400)
			return
		}
		w.WriteHeader(200)
		w.Write([]byte{1, 0, 9})
		w.(http.Flusher).Flush()
		<-release
		w.Write([]byte{1, 0, 8})
	}))
	h := &chunks{}
	h.on = func() {
		h.mu.Lock()
		first := h.n == 1
		h.mu.Unlock()
		// The first chunk arrived before the server wrote the second.
		if first {
			close(release)
		}
	}
	res, err := Stream(1, "POST", "/api/speech?room=r", `{"Content-Type":"application/json"}`, []byte(`{"text":"x"}`), h)
	if err != nil || res.Status != 200 {
		t.Fatalf("res=%v err=%v", res, err)
	}
	if !bytes.Equal(h.got.Bytes(), []byte{1, 0, 9, 1, 0, 8}) {
		t.Fatalf("body %v", h.got.Bytes())
	}
}

func TestStreamErrorStatusReturnsItsBody(t *testing.T) {
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(422)
		w.Write([]byte(`{"error":"nothing_to_speak"}`))
	}))
	h := &chunks{}
	res, err := Stream(2, "POST", "/api/speech", "", nil, h)
	if err != nil || res.Status != 422 || string(res.Body) != `{"error":"nothing_to_speak"}` || h.n != 0 {
		t.Fatalf("res=%v err=%v chunks=%d", res, err, h.n)
	}
}

func TestStreamCutBodyIsAnError(t *testing.T) {
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.Write([]byte{5, 0, 1})
		w.(http.Flusher).Flush()
		// Destroy the response mid-body, as the channel does when synthesis fails after the
		// first packet.
		conn, _, _ := w.(http.Hijacker).Hijack()
		conn.Close()
	}))
	if _, err := Stream(3, "POST", "/api/speech", "", nil, &chunks{}); err == nil {
		t.Fatal("a cut body returned no error")
	}
}

func TestStreamCancelEndsTheRequest(t *testing.T) {
	block := make(chan struct{})
	t.Cleanup(func() { close(block) })
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.Write([]byte{1, 0, 1})
		w.(http.Flusher).Flush()
		select {
		case <-block:
		case <-r.Context().Done():
		}
	}))
	h := &chunks{}
	h.on = func() { StreamCancel(4) }
	if _, err := Stream(4, "POST", "/api/speech", "", nil, h); err == nil {
		t.Fatal("a cancelled stream returned no error")
	}
}

func TestStreamCancelledBeforeItStartsIsNotSent(t *testing.T) {
	sent := false
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { sent = true }))
	StreamCancel(5)
	if _, err := Stream(5, "POST", "/api/speech", "", nil, &chunks{}); err == nil || sent {
		t.Fatalf("err=%v sent=%v", err, sent)
	}
}
