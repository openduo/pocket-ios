// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

package tsbridge

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type eventRecorder struct{ lines []string }

func (r *eventRecorder) Event(line string) { r.lines = append(r.lines, line) }

func useLogDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	logMu.Lock()
	logDir = dir
	logMu.Unlock()
	t.Cleanup(func() {
		SetLogging(false)
		SetEventHandler(nil)
		logMu.Lock()
		logDir = ""
		logMu.Unlock()
	})
	return dir
}

func TestLoggingOffWritesNothingAndRemovesTheFile(t *testing.T) {
	dir := useLogDir(t)
	path := filepath.Join(dir, "tsnet.log")
	if err := os.WriteFile(path, []byte("old\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	SetLogging(false)
	logf("netcheck: report: %s", "udp=false")
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("tsnet.log still there with logging off: %v", err)
	}
}

func TestLoggingOnDropsVerboseLines(t *testing.T) {
	dir := useLogDir(t)
	SetLogging(true)
	logf("[v1] Accept: TCP non-syn")
	logf("magicsock: [v2] disco ping")
	logf("control: map response %d", 7)
	b, err := os.ReadFile(filepath.Join(dir, "tsnet.log"))
	if err != nil {
		t.Fatal(err)
	}
	got := string(b)
	if strings.Contains(got, "Accept") || strings.Contains(got, "disco") {
		t.Fatalf("verbose lines written: %q", got)
	}
	if !strings.Contains(got, "map response 7") {
		t.Fatalf("ordinary line missing: %q", got)
	}
}

func TestMarkedLinesReachTheAppWithLoggingOff(t *testing.T) {
	useLogDir(t)
	r := &eventRecorder{}
	SetEventHandler(r)
	SetLogging(false)
	logf("magicsock: pocket: periodic STUN paused: no UDP path")
	logf("netcheck: report: udp=false")
	if len(r.lines) != 1 || !strings.Contains(r.lines[0], "periodic STUN paused") {
		t.Fatalf("events = %q", r.lines)
	}
}
