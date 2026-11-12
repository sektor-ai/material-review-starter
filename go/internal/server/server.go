package server

import (
	"context"
	"errors"
	"log/slog"
	"net/http"

	"connectrpc.com/connect"

	"github.com/sektor-ai/material-review-starter/go/gen/auth/v1/authv1connect"
	"github.com/sektor-ai/material-review-starter/go/gen/issue/v1/issuev1connect"
	"github.com/sektor-ai/material-review-starter/go/gen/pack/v1/packv1connect"
	"github.com/sektor-ai/material-review-starter/go/gen/review/v1/reviewv1connect"
	"github.com/sektor-ai/material-review-starter/go/internal/service"
	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

type Deps struct {
	Auth         *service.Auth
	Packs        *service.Packs
	Documents    *service.Documents
	Issues       *service.Issues
	Reviews      *service.Reviews
	Hub          *service.Hub
	Store        *store.Store
	CookieSecure bool
	// Ready reports whether the API's dependencies (the database) answer.
	// /healthz returns 503 when it fails, so "healthy" means able to serve.
	Ready func(context.Context) error
}

// New returns the HTTP handler for the whole API. Connect services are
// mounted under /api so the web app can reach them through one proxy prefix.
func New(d Deps) http.Handler {
	api := http.NewServeMux()
	api.Handle(authv1connect.NewAuthServiceHandler(NewAuthHandler(d.Auth, d.CookieSecure)))

	// Everything else requires a signed-in user.
	authed := connect.WithInterceptors(&authInterceptor{auth: d.Auth})
	api.Handle(packv1connect.NewPackServiceHandler(
		&PackHandler{packs: d.Packs, docs: d.Documents, hub: d.Hub, st: d.Store},
		authed,
		// Room for a MaxDocumentBytes upload plus the rest of the message.
		connect.WithReadMaxBytes(service.MaxDocumentBytes+1<<20),
	))
	api.Handle(issuev1connect.NewIssueServiceHandler(&IssueHandler{issues: d.Issues}, authed))
	api.Handle(reviewv1connect.NewReviewServiceHandler(&ReviewHandler{reviews: d.Reviews}, authed))
	api.Handle("GET /documents/{id}/original", documentOriginal(d.Auth, d.Documents))

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if d.Ready != nil {
			if err := d.Ready(r.Context()); err != nil {
				slog.ErrorContext(r.Context(), "health check failed", "err", err)
				w.WriteHeader(http.StatusServiceUnavailable)
				w.Write([]byte(`{"ok":false}`))
				return
			}
		}
		w.Write([]byte(`{"ok":true}`))
	})
	mux.Handle("/api/", http.StripPrefix("/api", api))
	return logRequests(mux)
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		slog.InfoContext(r.Context(), "request", "method", r.Method, "path", r.URL.Path, "status", rec.status)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// Flush lets server-streaming RPCs (WatchPack) push each message as it is
// sent; Connect needs an http.Flusher.
func (r *statusRecorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Unwrap exposes the underlying writer to http.ResponseController.
func (r *statusRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

func internal(err error) error {
	slog.Error("internal error", "err", err)
	return connect.NewError(connect.CodeInternal, errors.New("internal error"))
}
