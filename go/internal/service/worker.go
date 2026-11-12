package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

// Reviewer reviews one pack. It reports issues and progress through sink
// and returns a closing summary. It must stop when ctx is cancelled (the run
// was cancelled, or the server is shutting down).
type Reviewer interface {
	Review(ctx context.Context, job ReviewJob, sink ReviewSink) (summary string, err error)
}

type ReviewJob struct {
	Run       store.ReviewRun
	Pack      store.Pack
	Documents []ReviewDocument
}

type ReviewDocument struct {
	Document store.Document
	Content  string
}

// ReviewSink is how a Reviewer writes back. RecordIssue fails with a
// *PreconditionError once the run is no longer running.
type ReviewSink interface {
	RecordIssue(ctx context.Context, in CreateIssueInput) (store.Issue, error)
	Progress(ctx context.Context, note string)
	SetSessionID(ctx context.Context, sessionID string)
}

// Worker claims queued review runs and drives them through a Reviewer. Runs
// are leased: a run whose worker died is picked up again once its lease
// expires, and a cancelled run is noticed at the next lease renewal.
type Worker struct {
	st       *store.Store
	issues   *Issues
	reviewer Reviewer
	owner    string

	Lease        time.Duration
	PollInterval time.Duration
}

func NewWorker(st *store.Store, issues *Issues, reviewer Reviewer) *Worker {
	host, _ := os.Hostname()
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	return &Worker{
		st: st, issues: issues, reviewer: reviewer,
		owner:        fmt.Sprintf("%s-%d-%s", host, os.Getpid(), hex.EncodeToString(b)),
		Lease:        60 * time.Second,
		PollInterval: 2 * time.Second,
	}
}

// Run processes runs one at a time until ctx ends.
func (w *Worker) Run(ctx context.Context) {
	for {
		run, err := w.st.ClaimRun(ctx, w.owner, w.Lease)
		switch {
		case ctx.Err() != nil:
			return
		case errors.Is(err, store.ErrNotFound):
			select {
			case <-ctx.Done():
				return
			case <-time.After(w.PollInterval):
			}
		case err != nil:
			slog.Error("claiming review run", "err", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(w.PollInterval):
			}
		default:
			w.process(ctx, run)
		}
	}
}

func (w *Worker) process(ctx context.Context, run store.ReviewRun) {
	log := slog.With("run_id", run.ID, "pack_id", run.PackID)
	log.Info("review run started")

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		w.keepLease(runCtx, cancel, run.ID, log)
	}()

	summary, err := w.review(runCtx, run)
	cancel()
	wg.Wait()

	if ctx.Err() != nil {
		// Shutting down: leave the run to be picked up once the lease lapses.
		log.Info("review run interrupted by shutdown")
		return
	}
	status, errMsg := store.RunSucceeded, ""
	if err != nil {
		status, errMsg = store.RunFailed, err.Error()
	}
	var finished bool
	ferr := w.st.InPack(ctx, run.PackID, func(tx *store.PackTx) error {
		var err error
		if finished, err = tx.FinishRun(ctx, run.ID, w.owner, status, summary, errMsg); err != nil || !finished {
			return err
		}
		return reconcilePackStatus(ctx, tx)
	})
	switch {
	case ferr != nil:
		log.Error("recording review outcome", "err", ferr)
	case !finished:
		log.Info("review run was cancelled")
	default:
		log.Info("review run finished", "status", status)
	}
}

func (w *Worker) review(ctx context.Context, run store.ReviewRun) (string, error) {
	pack, err := w.st.GetPack(ctx, run.PackID)
	if err != nil {
		return "", fmt.Errorf("loading pack: %w", err)
	}
	docs, contents, err := w.st.ReadyDocuments(ctx, run.PackID)
	if err != nil {
		return "", fmt.Errorf("loading documents: %w", err)
	}
	job := ReviewJob{Run: run, Pack: pack}
	for i, d := range docs {
		job.Documents = append(job.Documents, ReviewDocument{Document: d, Content: contents[i]})
	}
	return w.reviewer.Review(ctx, job, &sink{w: w, runID: run.ID})
}

// keepLease renews the lease every third of its length and cancels the run
// context when the run is no longer ours (cancelled, or taken over).
func (w *Worker) keepLease(ctx context.Context, cancel context.CancelFunc, runID string, log *slog.Logger) {
	t := time.NewTicker(w.Lease / 3)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		ok, err := w.st.RenewLease(ctx, runID, w.owner, w.Lease)
		if err != nil {
			if ctx.Err() == nil {
				log.Warn("renewing review lease", "err", err)
			}
			continue
		}
		if !ok {
			cancel()
			return
		}
	}
}

type sink struct {
	w     *Worker
	runID string
}

func (s *sink) RecordIssue(ctx context.Context, in CreateIssueInput) (store.Issue, error) {
	return s.w.issues.RecordForRun(ctx, s.runID, in)
}

func (s *sink) Progress(ctx context.Context, note string) {
	if err := s.w.st.SetRunProgress(ctx, s.runID, s.w.owner, note, ""); err != nil && ctx.Err() == nil {
		slog.Warn("updating review progress", "run_id", s.runID, "err", err)
	}
}

func (s *sink) SetSessionID(ctx context.Context, sessionID string) {
	if err := s.w.st.SetRunProgress(ctx, s.runID, s.w.owner, "", sessionID); err != nil && ctx.Err() == nil {
		slog.Warn("recording agent session id", "run_id", s.runID, "err", err)
	}
}

// StubReviewer stands in for the Managed Agents reviewer. It reports
// progress, waits Delay, records no issues, and succeeds.
type StubReviewer struct {
	Delay time.Duration
}

func (r StubReviewer) Review(ctx context.Context, job ReviewJob, sink ReviewSink) (string, error) {
	sink.Progress(ctx, fmt.Sprintf("Stub reviewer: reading %d document(s) of %s", len(job.Documents), job.Pack.SubmittalNo))
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case <-time.After(r.Delay):
	}
	return "Stub review: no agent is connected yet, so no issues were recorded.", nil
}
