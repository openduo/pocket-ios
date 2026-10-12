// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

// mock-channel is a development tool that stands in for the ambient channel's message surface
// (docs/ble-protocol.md §2, §3), so the app's upload, RESULT and reply path can be exercised
// without a real channel. It does no ASR: the "transcript" describes the received packets. A
// message is accepted with 202; its row, `message cleaned` (voice), the turn and the answer
// arrive on /live, the answer after -answer-delay. Rows carry a cursor (`seq`): /live?since=
// replays the rows after it before `ready`, and /api/imlog?since= returns them without a socket.
// No /api/upload.
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
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

type entry struct {
	Seq         int64    `json:"seq"`
	At          string   `json:"at"`
	Kind        string   `json:"kind"`
	Speaker     string   `json:"speaker,omitempty"`
	Text        string   `json:"text"`
	UttID       string   `json:"utt_id,omitempty"`
	VoiceSource string   `json:"voice_source,omitempty"`
	MessageIDs  []string `json:"message_ids,omitempty"`
	Unspoken    bool     `json:"unspoken,omitempty"`
}

var (
	mu       sync.Mutex
	receipts = map[string][]byte{} // Idempotency-Key -> first 202 body
	imlog    []entry
	lastSeq  int64
	sockets  = map[*websocket.Conn]bool{}
	delay    = flag.Duration("answer-delay", 3*time.Second, "time from transcript to answer_final")
	noAnswer = flag.Bool("no-answer", false, "end each turn with turn idle and no answer (docs/ble-protocol.md §9)")
	// uploadMax is published as limits.upload_max_bytes; 0 publishes null (uploads off).
	uploadMax = flag.Int("upload-max", 0, "limits.upload_max_bytes in /api/state; 0 means null (uploads and voice off in the app)")
	uuidRE    = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

func main() {
	listen := flag.String("listen", "127.0.0.1:38199", "address to listen on")
	flag.Parse()
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true, "mock": true})
	})
	http.HandleFunc("/api/messages", message)
	gone := func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 410, map[string]string{"error": "update_required", "replacement": "/api/messages"})
	}
	http.HandleFunc("/api/voice", gone)
	http.HandleFunc("/api/inject", gone)
	http.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		var limit any
		if *uploadMax > 0 {
			limit = *uploadMax
		}
		writeJSON(w, 200, map[string]any{
			"room": r.URL.Query().Get("room"), "date": time.Now().Format("2006-01-02"),
			"daemon_ok": true, "cerebellum_ok": true, "limits": map[string]any{"upload_max_bytes": limit},
		})
	})
	http.HandleFunc("/api/imlog", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		mu.Lock()
		defer mu.Unlock()
		if s := q.Get("since"); s != "" {
			since, err := strconv.ParseInt(s, 10, 64)
			if err != nil || q.Get("date") != "" {
				writeJSON(w, 400, map[string]string{"error": "bad_since"})
				return
			}
			writeJSON(w, 200, map[string]any{"room": q.Get("room"), "entries": rowsAfter(since), "seq": lastSeq})
			return
		}
		date := q.Get("date")
		if _, err := time.Parse("2006-01-02", date); err != nil {
			writeJSON(w, 400, map[string]string{"error": "date must be YYYY-MM-DD"})
			return
		}
		rows := []entry{}
		for _, e := range imlog {
			if t, err := time.Parse(time.RFC3339, e.At); err == nil && t.Local().Format("2006-01-02") == date {
				rows = append(rows, e)
			}
		}
		writeJSON(w, 200, map[string]any{"room": q.Get("room"), "date": date, "entries": rows})
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

// rowsAfter returns the rows with seq above since; mu is held.
func rowsAfter(since int64) []entry {
	rows := []entry{}
	for _, e := range imlog {
		if e.Seq > since {
			rows = append(rows, e)
		}
	}
	return rows
}

// appendRow stamps the next seq (never below the clock, the channel's rule), logs the row and
// sends it on every socket.
func appendRow(e entry) {
	mu.Lock()
	lastSeq = max(lastSeq+1, time.Now().UnixMilli())
	e.Seq = lastSeq
	e.At = time.Now().UTC().Format(time.RFC3339)
	imlog = append(imlog, e)
	mu.Unlock()
	broadcast(map[string]any{"type": "row", "seq": e.Seq, "row": e})
}

func message(w http.ResponseWriter, r *http.Request) {
	key := strings.ToLower(r.Header.Get("Idempotency-Key"))
	if r.Method != "POST" {
		writeJSON(w, 405, map[string]string{"error": "method_not_allowed"})
		return
	}
	if !uuidRE.MatchString(key) {
		writeJSON(w, 400, map[string]string{"error": "idempotency_key_required"})
		return
	}
	mu.Lock()
	if prev, ok := receipts[key]; ok {
		mu.Unlock()
		log.Printf("message %s repeated: returning first receipt", key)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(202)
		w.Write(prev)
		return
	}
	mu.Unlock()
	body, _ := io.ReadAll(r.Body)
	switch r.Header.Get("Content-Type") {
	case "application/json":
		var m struct {
			Text string `json:"text"`
		}
		if json.Unmarshal(body, &m) != nil || strings.TrimSpace(m.Text) == "" {
			writeJSON(w, 400, map[string]string{"message_id": key, "error": "bad_body"})
			return
		}
		accept(w, key)
		go func() {
			appendRow(entry{Kind: "typed", Text: m.Text, UttID: key})
			answer(key, "收到："+m.Text)
		}()
	case "application/vnd.ambient.opus-packets":
		src := r.Header.Get("X-Voice-Source")
		n, bytes, ok := packets(body)
		if !ok || n == 0 || (src != "passport" && src != "phone") {
			writeJSON(w, 400, map[string]string{"message_id": key, "error": "bad_body"})
			return
		}
		accept(w, key)
		log.Printf("voice %s source=%s packets=%d bytes=%d", key, src, n, bytes)
		text := fmt.Sprintf("(mock %s) %d packets, %.1f s", src, n, float64(n)*0.02)
		go func() {
			// The row carries the text the brain receives; then the cleaned event.
			appendRow(entry{Kind: "typed", Text: text, UttID: key, VoiceSource: src})
			broadcast(map[string]any{"type": "message", "id": key, "state": "cleaned", "text": text})
			answer(key, "收到："+text)
		}()
	default:
		writeJSON(w, 415, map[string]string{"message_id": key, "error": "unsupported_media_type"})
	}
}

func accept(w http.ResponseWriter, key string) {
	res, _ := json.Marshal(map[string]string{"message_id": key, "at": time.Now().UTC().Format(time.RFC3339)})
	mu.Lock()
	receipts[key] = res
	mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(202)
	w.Write(res)
}

// packets counts `[u16 LE length][opus packet]` frames; ok is false on a truncated body.
func packets(body []byte) (n, bytes int, ok bool) {
	for off := 0; off < len(body); {
		if off+2 > len(body) {
			return n, bytes, false
		}
		l := int(binary.LittleEndian.Uint16(body[off:]))
		off += 2 + l
		if off > len(body) {
			return n, bytes, false
		}
		n++
		bytes += l
	}
	return n, bytes, true
}

// answer plays one brain turn for the message: received, thinking, a tool call, a partial
// answer, the answer and its row, then turn idle (docs/ble-protocol.md §9).
func answer(id, text string) {
	ids := []string{id}
	speech := "c-" + id
	turn := func(phase string) { broadcast(map[string]any{"type": "turn", "message_ids": ids, "phase": phase}) }
	turn("received")
	turn("thinking")
	time.Sleep(*delay / 4)
	turn("tool")
	time.Sleep(*delay / 4)
	if *noAnswer {
		time.Sleep(*delay / 2)
		turn("idle")
		log.Printf("turn idle without answer %s", id)
		return
	}
	broadcast(map[string]any{"type": "duoduo_said", "speech_id": speech, "text": string([]rune(text)[:len([]rune(text))/2]), "kind": "answer"})
	time.Sleep(*delay / 2)
	broadcast(map[string]any{"type": "answer_final", "speech_id": speech, "message_ids": ids, "text": text})
	appendRow(entry{Kind: "answer", Speaker: "多多", Text: text, MessageIDs: ids, Unspoken: true})
	log.Printf("answer_final %s", speech)
	turn("idle")
}

func send(c *websocket.Conn, v any) {
	b, _ := json.Marshal(v)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	c.Write(ctx, websocket.MessageText, b)
	cancel()
}

func broadcast(v any) {
	mu.Lock()
	defer mu.Unlock()
	for c := range sockets {
		send(c, v)
	}
}

// live is the /live connection: meta, the rows after `since` (when given), ready, then live
// events. The mock has no capture seat; a hello is ignored.
func live(w http.ResponseWriter, r *http.Request) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	mu.Lock()
	send(c, map[string]any{"type": "meta", "conn": fmt.Sprintf("mock-%d", time.Now().UnixNano())})
	if s := r.URL.Query().Get("since"); s != "" {
		if since, err := strconv.ParseInt(s, 10, 64); err == nil {
			for _, e := range rowsAfter(since) {
				send(c, map[string]any{"type": "row", "seq": e.Seq, "row": e})
			}
		}
	}
	send(c, map[string]any{"type": "ready", "seq": lastSeq, "turn": nil, "messages": []any{}, "api": 1})
	sockets[c] = true
	n := len(sockets)
	mu.Unlock()
	log.Printf("live socket open (%d)", n)
	for {
		if _, _, err := c.Read(context.Background()); err != nil {
			break
		}
	}
	mu.Lock()
	delete(sockets, c)
	mu.Unlock()
	log.Printf("live socket closed")
}
