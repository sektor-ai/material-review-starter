package server

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthz(t *testing.T) {
	tests := []struct {
		name  string
		ready func(context.Context) error
		want  int
	}{
		{"ready", func(context.Context) error { return nil }, http.StatusOK},
		// A database that is unreachable, or whose schema is behind this build,
		// must fail the check: Cloud Run's startup probe uses it to keep such a
		// revision from taking traffic.
		{"not ready", func(context.Context) error { return errors.New("schema behind") }, http.StatusServiceUnavailable},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := New(Deps{Ready: tt.ready})
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
			if rec.Code != tt.want {
				t.Fatalf("GET /healthz = %d, want %d", rec.Code, tt.want)
			}
		})
	}
}
