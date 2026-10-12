// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

package tsbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
)

// StreamHandler receives the body of a streamed response as it arrives.
// Implemented on the Swift side; called on the calling Go thread.
type StreamHandler interface {
	OnStreamData(data []byte)
}

var (
	streamMu     sync.Mutex
	streamCancel = map[int64]context.CancelFunc{}
	// streamCancelled holds ids cancelled before Stream registered them: the
	// caller may cancel between deciding to send and the request starting.
	streamCancelled = map[int64]bool{}
)

// Stream performs one HTTP request whose 200 body is delivered to h as it
// arrives (a read aloud streams audio while it is synthesized). Any other
// status returns its whole body in the Response, and h is not called. A 200
// body that ends cleanly returns Response{Status: 200}; one that breaks returns
// an error, so a cut stream is never mistaken for a whole one. There is no
// deadline: StreamCancel(id) ends the request.
func Stream(id int64, method, path, headersJSON string, body []byte, h StreamHandler) (*Response, error) {
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
	ctx, cancel := context.WithCancel(context.Background())
	streamMu.Lock()
	early := streamCancelled[id]
	delete(streamCancelled, id)
	streamCancel[id] = cancel
	streamMu.Unlock()
	if early {
		cancel()
	}
	defer func() {
		streamMu.Lock()
		delete(streamCancel, id)
		streamMu.Unlock()
		cancel()
	}()
	req, err := http.NewRequestWithContext(ctx, method, base+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	if headersJSON != "" {
		var hd map[string]string
		if err := json.Unmarshal([]byte(headersJSON), &hd); err != nil {
			return nil, fmt.Errorf("tsbridge: headers: %w", err)
		}
		for k, v := range hd {
			req.Header.Set(k, v)
		}
	}
	req.ContentLength = int64(len(body))
	res, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		b, err := io.ReadAll(res.Body)
		if err != nil {
			return nil, err
		}
		return &Response{Status: res.StatusCode, Body: b}, nil
	}
	return &Response{Status: res.StatusCode}, deliver(res.Body, h)
}

// deliver copies the body to h as it is read, until EOF or an error.
func deliver(r io.Reader, h StreamHandler) error {
	_, err := io.Copy(handlerWriter{h}, r)
	return err
}

type handlerWriter struct{ h StreamHandler }

func (w handlerWriter) Write(p []byte) (int, error) {
	w.h.OnStreamData(p)
	return len(p), nil
}

// StreamCancel ends the request started by Stream with this id; Stream then
// returns an error. An id not yet started is remembered, and its Stream ends at
// once without sending: call it only for a request that is about to start or
// running, never after Stream returned.
func StreamCancel(id int64) {
	streamMu.Lock()
	cancel := streamCancel[id]
	if cancel == nil {
		streamCancelled[id] = true
	}
	streamMu.Unlock()
	if cancel != nil {
		cancel()
	}
}
