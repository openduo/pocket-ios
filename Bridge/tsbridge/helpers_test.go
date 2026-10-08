// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

package tsbridge

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"testing"
)

// setupUpstream points the bridge at a local test server instead of tsnet.
func setupUpstream(t *testing.T, h http.Handler) {
	t.Helper()
	up := httptest.NewServer(h)
	t.Cleanup(up.Close)
	u, _ := url.Parse(up.URL)
	port, _ := strconv.Atoi(u.Port())
	mu.Lock()
	tr = http.DefaultTransport.(*http.Transport).Clone()
	client = &http.Client{Transport: tr}
	mu.Unlock()
	SetTarget("localhost", port, false)
}
