// demo-apps/event-generator/handlers_test.go
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHealthzReturns200WhenReady(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	mux := newMux(rc, func() bool { return true }, NewEventLog())
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestHealthzReturns503WhenNotReady(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	mux := newMux(rc, func() bool { return false }, NewEventLog())
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", rec.Code)
	}
}

func TestTriggerHighLoadEndpointStartsHighLoad(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	mux := newMux(rc, func() bool { return true }, NewEventLog())
	req := httptest.NewRequest(http.MethodPost, "/api/load/high", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if !rc.IsHighLoad() {
		t.Fatal("expected rate controller to be in high load after POST /api/load/high")
	}
}

func TestIndexServesHTML(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	mux := newMux(rc, func() bool { return true }, NewEventLog())
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "" && ct != "text/html; charset=utf-8" {
		t.Fatalf("unexpected content type %q", ct)
	}
}

func TestRecentEventsReturnsNewestFirstWithStats(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	evlog := NewEventLog()
	for i := 0; i < 3; i++ {
		evlog.Add(Event{Timestamp: time.Now(), EventType: "click", Value: float64(i), UserID: uint32(i)})
	}
	evlog.AddFailure()
	mux := newMux(rc, func() bool { return true }, evlog)
	req := httptest.NewRequest(http.MethodGet, "/api/events/recent?limit=2", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var body struct {
		Events []struct {
			UserID uint32 `json:"userId"`
		} `json:"events"`
		Stats Stats `json:"stats"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Events) != 2 || body.Events[0].UserID != 2 || body.Events[1].UserID != 1 {
		t.Fatalf("expected user ids [2 1], got %+v", body.Events)
	}
	if body.Stats.Total != 3 || body.Stats.Failed != 1 || body.Stats.ByType["click"] != 3 {
		t.Fatalf("unexpected stats %+v", body.Stats)
	}
}
