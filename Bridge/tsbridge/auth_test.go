// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

package tsbridge

import (
	"context"
	"net/http"
	"testing"

	"github.com/coder/websocket"
)

// authEcho records each request's Authorization header and accepts /live.
func authEcho(t *testing.T) <-chan string {
	got := make(chan string, 8)
	setupUpstream(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got <- r.Header.Get("Authorization")
		if r.URL.Path == "/live" {
			c, err := websocket.Accept(w, r, nil)
			if err != nil {
				return
			}
			defer c.CloseNow()
			_, _, _ = c.Read(context.Background())
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	return got
}

func retarget(token string) {
	t := currentTarget()
	SetTarget(t.Host, t.Port, t.TLS, token)
}

// The target's token goes on requests, streams and the /live upgrade.
func TestTargetTokenIsSent(t *testing.T) {
	got := authEcho(t)
	retarget("tok")
	t.Cleanup(func() { LiveClose() })
	if _, err := Do("GET", "/api/state", "", nil, 2000); err != nil {
		t.Fatal(err)
	}
	if a := <-got; a != "Bearer tok" {
		t.Fatalf("Do Authorization = %q", a)
	}
	if _, err := Stream(901, "POST", "/api/speech", "", nil, &chunks{}); err != nil {
		t.Fatal(err)
	}
	if a := <-got; a != "Bearer tok" {
		t.Fatalf("Stream Authorization = %q", a)
	}
	if err := LiveOpen("/live", "", 2000); err != nil {
		t.Fatal(err)
	}
	if a := <-got; a != "Bearer tok" {
		t.Fatalf("LiveOpen Authorization = %q", a)
	}
}

// A target set without a token (a pairing request to a new host) sends none,
// and a caller's own Authorization wins over the target's.
func TestTargetWithoutTokenSendsNone(t *testing.T) {
	got := authEcho(t)
	retarget("")
	if _, err := Do("POST", "/api/pair", `{"Content-Type":"application/json"}`, []byte(`{"code":"c"}`), 2000); err != nil {
		t.Fatal(err)
	}
	if a := <-got; a != "" {
		t.Fatalf("Authorization = %q, want none", a)
	}
	retarget("tok")
	if _, err := Do("GET", "/healthz", `{"Authorization":"Bearer other"}`, nil, 2000); err != nil {
		t.Fatal(err)
	}
	if a := <-got; a != "Bearer other" {
		t.Fatalf("Authorization = %q", a)
	}
}
