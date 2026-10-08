// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

// mock-channel is a development tool that stands in for the ambient channel's voice-note
// surface (docs/ble-protocol.md §2, §3), so the app's upload, RESULT and reply path can be
// exercised without a real channel. It does no ASR: the "transcript" describes the received
// packets, and the "answer" arrives on /live after -answer-delay. /api/state and /api/imlog
// serve the in-memory room log with utt_id on notes and answers. No /api/upload or /api/inject.
//
//	go run . -listen <tailnet-ip>:38199 [-answer-delay 3s] [-no-answer] [-upload-max 0]
//
// Then set the app's host to that address, port 38199, HTTPS off.
package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

type entry struct {
	At          string `json:"at"`
	Kind        string `json:"kind"`
	Speaker     string `json:"speaker,omitempty"`
	Text        string `json:"text"`
	UttID       string `json:"utt_id,omitempty"`
	VoiceSource string `json:"voice_source,omitempty"`
}

var (
	mu       sync.Mutex
	results  = map[string][]byte{} // X-Voice-Id -> first response body
	imlog    []entry
	sockets  = map[*websocket.Conn]bool{}
	delay    = flag.Duration("answer-delay", 3*time.Second, "time from transcript to answer_final")
	noAnswer = flag.Bool("no-answer", false, "end each turn with turn idle and no answer (docs/ble-protocol.md §9)")
	// uploadMax is published as limits.upload_max_bytes; 0 publishes null (uploads off).
	uploadMax = flag.Int("upload-max", 0, "limits.upload_max_bytes in /api/state; 0 means null (uploads and voice off in the app)")
	seq       int
)

func main() {
	listen := flag.String("listen", "127.0.0.1:38199", "address to listen on")
	flag.Parse()
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true, "mock": true})
	})
	http.HandleFunc("/api/voice", voice)
	http.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		var limit any
		if *uploadMax > 0 {
			limit = *uploadMax
		}
		writeJSON(w, 200, map[string]any{
			"room": r.URL.Query().Get("room"), "date": time.Now().Format("2006-01-02"),
			"imlog": imlog, "limits": map[string]any{"upload_max_bytes": limit},
		})
	})
	http.HandleFunc("/api/imlog", func(w http.ResponseWriter, r *http.Request) {
		date := r.URL.Query().Get("date")
		if _, err := time.Parse("2006-01-02", date); err != nil {
			writeJSON(w, 400, map[string]string{"error": "date must be YYYY-MM-DD"})
			return
		}
		mu.Lock()
		defer mu.Unlock()
		rows := []entry{}
		for _, e := range imlog {
			if t, err := time.Parse(time.RFC3339, e.At); err == nil && t.Local().Format("2006-01-02") == date {
				rows = append(rows, e)
			}
		}
		writeJSON(w, 200, map[string]any{"room": r.URL.Query().Get("room"), "date": date, "entries": rows})
	})
	http.HandleFunc("/live", live)
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "<!doctype html><meta charset=utf-8><title>mock channel</title><p>mock channel: room "+r.URL.Query().Get("room")+"</p>")
	})
	log.Printf("mock channel on http://%s", *listen)
	log.Fatal(http.ListenAndServe(*listen, nil))
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func voice(w http.ResponseWriter, r *http.Request) {
	id := r.Header.Get("X-Voice-Id")
	src := r.Header.Get("X-Voice-Source")
	if r.Method != "POST" || id == "" || r.Header.Get("Content-Type") != "application/vnd.ambient.opus-packets" {
		writeJSON(w, 400, map[string]string{"voice_id": id, "error": "bad_body"})
		return
	}
	body, _ := io.ReadAll(r.Body)
	mu.Lock()
	if prev, ok := results[id]; ok {
		mu.Unlock()
		log.Printf("voice %s repeated: returning first result", id)
		w.Header().Set("Content-Type", "application/json")
		w.Write(prev)
		return
	}
	mu.Unlock()
	n, bytes := 0, 0
	for off := 0; off < len(body); {
		if off+2 > len(body) {
			writeJSON(w, 400, map[string]string{"voice_id": id, "error": "bad_body"})
			return
		}
		l := int(binary.LittleEndian.Uint16(body[off:]))
		off += 2 + l
		if off > len(body) {
			writeJSON(w, 400, map[string]string{"voice_id": id, "error": "bad_body"})
			return
		}
		n++
		bytes += l
	}
	if n == 0 {
		writeJSON(w, 422, map[string]string{"voice_id": id, "error": "empty_transcript"})
		return
	}
	text := fmt.Sprintf("(mock %s) %d packets, %.1f s", src, n, float64(n)*0.02)
	mu.Lock()
	seq++
	utt := fmt.Sprintf("mock-%d", seq)
	speech := "c-" + utt
	res, _ := json.Marshal(map[string]string{"voice_id": id, "text": text, "utt_id": utt})
	results[id] = res
	imlog = append(imlog, entry{At: time.Now().UTC().Format(time.RFC3339), Kind: "typed", Text: text, UttID: utt, VoiceSource: src})
	mu.Unlock()
	log.Printf("voice %s source=%s packets=%d bytes=%d", id, src, n, bytes)
	w.Header().Set("Content-Type", "application/json")
	w.Write(res)
	go answer(utt, speech, "收到："+text)
}

// answer plays one brain turn: thinking, a tool call, a partial answer, the
// answer, then turn idle (the channel's work-status frames, docs/ble-protocol.md §9).
func answer(utt, speech, text string) {
	turn := func(phase string) { broadcast(map[string]any{"type": "turn", "utt_id": nil, "phase": phase}) }
	turn("thinking")
	time.Sleep(*delay / 4)
	turn("tool")
	time.Sleep(*delay / 4)
	if *noAnswer {
		time.Sleep(*delay / 2)
		turn("idle")
		log.Printf("turn idle without answer %s", speech)
		return
	}
	broadcast(map[string]any{"type": "duoduo_said", "speech_id": speech, "utt_id": utt, "text": string([]rune(text)[:len([]rune(text))/2]), "kind": "answer"})
	time.Sleep(*delay / 2)
	mu.Lock()
	imlog = append(imlog, entry{At: time.Now().UTC().Format(time.RFC3339), Kind: "answer", Speaker: "多多", Text: text, UttID: utt})
	mu.Unlock()
	broadcast(map[string]any{"type": "answer_final", "speech_id": speech, "utt_id": utt, "text": text})
	log.Printf("answer_final %s", speech)
	turn("idle")
}

func broadcast(v any) {
	b, _ := json.Marshal(v)
	mu.Lock()
	defer mu.Unlock()
	for c := range sockets {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		c.Write(ctx, websocket.MessageText, b)
		cancel()
	}
}

func live(w http.ResponseWriter, r *http.Request) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	mu.Lock()
	sockets[c] = true
	n := len(sockets)
	mu.Unlock()
	log.Printf("display socket open (%d)", n)
	for {
		if _, _, err := c.Read(context.Background()); err != nil {
			break
		}
	}
	mu.Lock()
	delete(sockets, c)
	mu.Unlock()
	log.Printf("display socket closed")
}
