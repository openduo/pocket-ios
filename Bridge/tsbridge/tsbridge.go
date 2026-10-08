// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

// Package tsbridge is the app's embedded Tailscale node, bound into an
// xcframework with gomobile. It owns:
//
//   - the tsnet node (userspace, state in the app container);
//   - native HTTP requests to the channel;
//   - the display WebSocket (no hello) and the ambient edge WebSocket (hello,
//     binary audio both ways).
//
// Nothing listens on the phone: every call dials out through tsnet.
package tsbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tailscale.com/tsnet"
)

var (
	mu  sync.Mutex
	srv *tsnet.Server
	// logMu guards logFile only. tsnet logs from inside Start, which holds mu,
	// so the logger must not take mu.
	logMu   sync.Mutex
	logFile *os.File
	tr      *http.Transport
	client  *http.Client
	target  chanTarget
)

// chanTarget is the channel host that native requests and both sockets reach.
type chanTarget struct {
	Host string
	Port int
	TLS  bool
}

func (t chanTarget) hostPort() string {
	if (t.TLS && t.Port == 443) || (!t.TLS && t.Port == 80) || t.Port == 0 {
		return t.Host
	}
	return net.JoinHostPort(t.Host, fmt.Sprint(t.Port))
}

func (t chanTarget) scheme() string {
	if t.TLS {
		return "https"
	}
	return "http"
}

func (t chanTarget) origin() string { return t.scheme() + "://" + t.hostPort() }

func logf(format string, args ...any) {
	logMu.Lock()
	defer logMu.Unlock()
	f := logFile
	if f != nil {
		fmt.Fprintf(f, time.Now().UTC().Format(time.RFC3339Nano)+" "+format+"\n", args...)
	}
}

// Start creates and starts the tsnet node. stateDir must persist across
// launches so the node identity survives. A second call is a no-op.
func Start(stateDir, hostname string) error {
	mu.Lock()
	defer mu.Unlock()
	if srv != nil {
		return nil
	}
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return err
	}
	// Do not upload tailscaled logs to log.tailscale.io from the app.
	os.Setenv("TS_NO_LOGS_NO_SUPPORT", "true")
	lf, _ := os.OpenFile(filepath.Join(stateDir, "tsnet.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	logMu.Lock()
	logFile = lf
	logMu.Unlock()
	s := &tsnet.Server{
		Dir:      stateDir,
		Hostname: hostname,
		Logf:     func(format string, args ...any) { logf(format, args...) },
		UserLogf: func(format string, args ...any) { logf(format, args...) },
	}
	if err := s.Start(); err != nil {
		// A retry opens the log again; do not leak this handle.
		logMu.Lock()
		logFile = nil
		logMu.Unlock()
		if lf != nil {
			lf.Close()
		}
		return err
	}
	srv = s
	// One shared transport so connections are reused. Go's DefaultTransport
	// timeouts are kept; only the dialer changes.
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.Proxy = nil
	t.DialContext = s.Dial
	tr = t
	client = &http.Client{Transport: t}
	return nil
}

func server() (*tsnet.Server, error) {
	mu.Lock()
	defer mu.Unlock()
	if srv == nil {
		return nil, errors.New("tsbridge: not started")
	}
	return srv, nil
}

// TSLogPath returns the tsnet log file path (for log export).
func TSLogPath() string {
	logMu.Lock()
	defer logMu.Unlock()
	if logFile == nil {
		return ""
	}
	return logFile.Name()
}

type status struct {
	BackendState string   `json:"backend_state"`
	AuthURL      string   `json:"auth_url,omitempty"`
	IPs          []string `json:"ips,omitempty"`
	DNSName      string   `json:"dns_name,omitempty"`
	Error        string   `json:"error,omitempty"`
}

// Status returns JSON: backend state, login URL when login is needed,
// tailnet IPs and DNS name.
func Status() string {
	out := status{}
	s, err := server()
	if err != nil {
		out.BackendState = "NotStarted"
		return mustJSON(out)
	}
	lc, err := s.LocalClient()
	if err != nil {
		out.Error = err.Error()
		return mustJSON(out)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	st, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		out.Error = err.Error()
		return mustJSON(out)
	}
	out.BackendState = st.BackendState
	out.AuthURL = st.AuthURL
	for _, ip := range st.TailscaleIPs {
		out.IPs = append(out.IPs, ip.String())
	}
	if st.Self != nil {
		out.DNSName = st.Self.DNSName
	}
	return mustJSON(out)
}

// Logout logs the node out of the tailnet. The next Status reports
// NeedsLogin with a fresh auth URL.
func Logout() error {
	s, err := server()
	if err != nil {
		return err
	}
	lc, err := s.LocalClient()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return lc.Logout(ctx)
}

// Up blocks until the backend reports Running or the timeout elapses.
func Up(timeoutMs int64) error {
	s, err := server()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	_, err = s.Up(ctx)
	return err
}

// SetTarget sets the channel host. Host is a tailnet name or address.
func SetTarget(host string, port int, useTLS bool) {
	mu.Lock()
	target = chanTarget{Host: strings.TrimSpace(host), Port: port, TLS: useTLS}
	mu.Unlock()
}

func currentTarget() chanTarget {
	mu.Lock()
	defer mu.Unlock()
	return target
}

// BaseURL returns scheme://host[:port] for the current target, or "".
func BaseURL() string {
	t := currentTarget()
	if t.Host == "" {
		return ""
	}
	return t.origin()
}

// CloseIdle drops pooled connections. Call after a wake: connections that
// sat through a suspension are usually dead and would cost one timeout.
func CloseIdle() {
	mu.Lock()
	t := tr
	mu.Unlock()
	if t != nil {
		t.CloseIdleConnections()
	}
}

// Response is the result of Do.
type Response struct {
	Status int
	Body   []byte
}

// Do performs one HTTP request over the tailnet. path is appended to the
// target base URL (it must start with "/"). headersJSON is a JSON object of
// header name to value. A transport error returns err; any HTTP status
// returns a Response.
func Do(method, path, headersJSON string, body []byte, timeoutMs int64) (*Response, error) {
	mu.Lock()
	c := client
	mu.Unlock()
	if c == nil {
		return nil, errors.New("tsbridge: not started")
	}
	base := BaseURL()
	if base == "" {
		return nil, errors.New("tsbridge: no target host")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, base+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	if headersJSON != "" {
		var h map[string]string
		if err := json.Unmarshal([]byte(headersJSON), &h); err != nil {
			return nil, fmt.Errorf("tsbridge: headers: %w", err)
		}
		for k, v := range h {
			req.Header.Set(k, v)
		}
	}
	req.ContentLength = int64(len(body))
	res, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	b, err := io.ReadAll(res.Body)
	if err != nil {
		return nil, err
	}
	return &Response{Status: res.StatusCode, Body: b}, nil
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
