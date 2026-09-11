// demo-apps/event-generator/handlers_test.go
package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHealthzReturns200WhenReady(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	mux := newMux(rc, func() bool { return true })
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestHealthzReturns503WhenNotReady(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	mux := newMux(rc, func() bool { return false })
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", rec.Code)
	}
}

func TestTriggerHighLoadEndpointStartsHighLoad(t *testing.T) {
	rc := NewRateController(30 * time.Second)
	mux := newMux(rc, func() bool { return true })
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
	mux := newMux(rc, func() bool { return true })
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
