// Command api runs the HTTP API server.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/sektor-ai/material-review-starter/go/internal/config"
	"github.com/sektor-ai/material-review-starter/go/internal/server"
	"github.com/sektor-ai/material-review-starter/go/internal/service"
	"github.com/sektor-ai/material-review-starter/go/internal/storage"
	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

func main() {
	if os.Getenv("K_SERVICE") != "" { // running on Cloud Run
		slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	}
	if err := run(); err != nil {
		slog.Error("api exited", "err", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg, err := config.Load()
	if err != nil {
		return err
	}
	st, err := store.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer st.Close()

	files, err := storage.New(cfg.S3)
	if err != nil {
		return err
	}

	issues := service.NewIssues(st)
	hub := service.NewHub(st)
	// The Managed Agents reviewer is not wired up yet; the stub records no
	// issues and succeeds, so the run lifecycle works end to end.
	worker := service.NewWorker(st, issues, service.StubReviewer{Delay: 3 * time.Second})

	// Background loops stop when run returns, however it returns.
	bgCtx, stopBg := context.WithCancel(ctx)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); hub.Run(bgCtx) }()
	go func() { defer wg.Done(); worker.Run(bgCtx) }()
	defer wg.Wait()
	defer stopBg() // runs before wg.Wait

	srv := &http.Server{
		Addr: fmt.Sprintf(":%d", cfg.Port),
		Handler: server.New(server.Deps{
			Auth:         service.NewAuth(st),
			Packs:        service.NewPacks(st),
			Documents:    service.NewDocuments(st, files),
			Issues:       issues,
			Reviews:      service.NewReviews(st),
			Hub:          hub,
			Store:        st,
			CookieSecure: cfg.CookieSecure,
			Ready:        st.Ready,
		}),
		ReadHeaderTimeout: 10 * time.Second,
		// Stream (WatchPack) contexts end with the server's base context, so
		// shutdown does not wait out open watches.
		BaseContext: func(net.Listener) context.Context { return ctx },
	}

	errCh := make(chan error, 1)
	go func() {
		slog.Info("API listening", "addr", "http://localhost"+srv.Addr)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("shutting down: %w", err)
	}
	return nil
}
