package service

import (
	"context"
	"errors"
	"strings"

	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

// Reviews queues and tracks agent review runs. The Worker executes them.
type Reviews struct {
	st *store.Store
}

func NewReviews(st *store.Store) *Reviews { return &Reviews{st: st} }

// Start queues a review of a pack that is not final, has no active run and
// has at least one READY document.
func (r *Reviews) Start(ctx context.Context, actor store.User, packID, instructions string) (store.ReviewRun, error) {
	if err := checkID("pack_id", packID); err != nil {
		return store.ReviewRun{}, err
	}
	var out store.ReviewRun
	err := r.st.InPack(ctx, packID, func(tx *store.PackTx) error {
		if err := packFinal(tx.Pack()); err != nil {
			return err
		}
		if _, err := tx.ActiveRun(ctx); err == nil {
			return precondition("pack %s already has a review in progress", tx.Pack().SubmittalNo)
		} else if !errors.Is(err, store.ErrNotFound) {
			return err
		}
		ready, err := tx.ReadyDocumentCount(ctx)
		if err != nil {
			return err
		}
		if ready == 0 {
			return precondition("pack %s has no parsed documents to review", tx.Pack().SubmittalNo)
		}
		out, err = tx.InsertRun(ctx, actor.ID, strings.TrimSpace(instructions))
		if errors.Is(err, store.ErrRunActive) {
			return precondition("pack %s already has a review in progress", tx.Pack().SubmittalNo)
		}
		return err
	})
	return out, notFoundAs(err, "pack")
}

func (r *Reviews) Get(ctx context.Context, id string) (store.ReviewRun, error) {
	if err := checkID("id", id); err != nil {
		return store.ReviewRun{}, err
	}
	run, err := r.st.GetRun(ctx, id)
	return run, notFoundAs(err, "review run")
}

func (r *Reviews) List(ctx context.Context, packID string) ([]store.ReviewRun, error) {
	if err := checkID("pack_id", packID); err != nil {
		return nil, err
	}
	if _, err := r.st.GetPack(ctx, packID); err != nil {
		return nil, notFoundAs(err, "pack")
	}
	return r.st.ListRuns(ctx, packID)
}

// Cancel stops a queued or running review. Issues already recorded stay.
func (r *Reviews) Cancel(ctx context.Context, id string) (store.ReviewRun, error) {
	if err := checkID("id", id); err != nil {
		return store.ReviewRun{}, err
	}
	packID, err := r.st.PackIDOf(ctx, "review_runs", id)
	if err != nil {
		return store.ReviewRun{}, notFoundAs(err, "review run")
	}
	var out store.ReviewRun
	err = r.st.InPack(ctx, packID, func(tx *store.PackTx) error {
		run, err := tx.Run(ctx, id)
		if err != nil {
			return err
		}
		if !run.Status.Active() {
			return precondition("review run already %s", run.Status)
		}
		if err := tx.CancelActiveRuns(ctx); err != nil {
			return err
		}
		out, err = tx.Run(ctx, id)
		return err
	})
	return out, notFoundAs(err, "review run")
}
