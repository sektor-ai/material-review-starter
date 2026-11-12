package service

import (
	"context"
	"errors"
	"strings"

	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

// Packs manages packs (material submittals) and their status.
type Packs struct {
	st *store.Store
}

func NewPacks(st *store.Store) *Packs { return &Packs{st: st} }

type CreatePackInput struct {
	SubmittalNo string
	Title       string
	DesignBasis string
}

func (p *Packs) Create(ctx context.Context, actor store.User, in CreatePackInput) (store.Pack, error) {
	in.SubmittalNo = strings.TrimSpace(in.SubmittalNo)
	in.Title = strings.TrimSpace(in.Title)
	if in.SubmittalNo == "" {
		return store.Pack{}, invalid("submittal_no is required")
	}
	if in.Title == "" {
		return store.Pack{}, invalid("title is required")
	}
	return p.st.CreatePack(ctx, store.NewPack{
		SubmittalNo: in.SubmittalNo,
		Title:       in.Title,
		DesignBasis: strings.TrimSpace(in.DesignBasis),
		CreatedBy:   actor.ID,
	})
}

func (p *Packs) List(ctx context.Context) ([]store.Pack, error) { return p.st.ListPacks(ctx) }

// Get returns the pack, its documents, and its latest run (nil if never
// reviewed).
func (p *Packs) Get(ctx context.Context, id string) (store.Pack, []store.Document, *store.ReviewRun, error) {
	if err := checkID("id", id); err != nil {
		return store.Pack{}, nil, nil, err
	}
	pack, err := p.st.GetPack(ctx, id)
	if err != nil {
		return store.Pack{}, nil, nil, notFoundAs(err, "pack")
	}
	docs, err := p.st.ListDocuments(ctx, id)
	if err != nil {
		return store.Pack{}, nil, nil, err
	}
	run, err := p.LatestRun(ctx, id)
	if err != nil {
		return store.Pack{}, nil, nil, err
	}
	return pack, docs, run, nil
}

// LatestRun returns the pack's newest run, or nil.
func (p *Packs) LatestRun(ctx context.Context, packID string) (*store.ReviewRun, error) {
	run, err := p.st.LatestRun(ctx, packID)
	if errors.Is(err, store.ErrNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &run, nil
}

func (p *Packs) Update(ctx context.Context, id string, title, designBasis *string) (store.Pack, error) {
	if err := checkID("id", id); err != nil {
		return store.Pack{}, err
	}
	if title != nil {
		t := strings.TrimSpace(*title)
		if t == "" {
			return store.Pack{}, invalid("title cannot be empty")
		}
		title = &t
	}
	var out store.Pack
	err := p.st.InPack(ctx, id, func(tx *store.PackTx) error {
		if err := packFinal(tx.Pack()); err != nil {
			return err
		}
		if err := tx.UpdatePackDetails(ctx, title, designBasis); err != nil {
			return err
		}
		var err error
		out, err = tx.ReloadPack(ctx)
		return err
	})
	return out, notFoundAs(err, "pack")
}

// Approve marks a RESOLVED pack with no active review as APPROVED.
func (p *Packs) Approve(ctx context.Context, actor store.User, id string) (store.Pack, error) {
	if err := checkID("id", id); err != nil {
		return store.Pack{}, err
	}
	var out store.Pack
	err := p.st.InPack(ctx, id, func(tx *store.PackTx) error {
		pack := tx.Pack()
		if pack.Status != store.PackResolved {
			return precondition("only a resolved pack can be approved; %s is %s", pack.SubmittalNo, pack.Status)
		}
		if _, err := tx.ActiveRun(ctx); err == nil {
			return precondition("pack %s has a review in progress", pack.SubmittalNo)
		} else if !errors.Is(err, store.ErrNotFound) {
			return err
		}
		if err := tx.ApprovePack(ctx, actor.ID); err != nil {
			return err
		}
		var err error
		out, err = tx.ReloadPack(ctx)
		return err
	})
	return out, notFoundAs(err, "pack")
}

// Cancel marks an OPEN or RESOLVED pack as CANCELLED and cancels its active
// review, if any.
func (p *Packs) Cancel(ctx context.Context, actor store.User, id, reason string) (store.Pack, error) {
	if err := checkID("id", id); err != nil {
		return store.Pack{}, err
	}
	var out store.Pack
	err := p.st.InPack(ctx, id, func(tx *store.PackTx) error {
		if err := packFinal(tx.Pack()); err != nil {
			return err
		}
		if err := tx.CancelActiveRuns(ctx); err != nil {
			return err
		}
		if err := tx.CancelPack(ctx, actor.ID, strings.TrimSpace(reason)); err != nil {
			return err
		}
		var err error
		out, err = tx.ReloadPack(ctx)
		return err
	})
	return out, notFoundAs(err, "pack")
}

// nextPackStatus is the automatic status: RESOLVED once a review has
// succeeded and no issue is open, OPEN otherwise. Final statuses stay.
func nextPackStatus(current store.PackStatus, hasSucceededRun bool, openIssues int) store.PackStatus {
	if current.Final() {
		return current
	}
	if hasSucceededRun && openIssues == 0 {
		return store.PackResolved
	}
	return store.PackOpen
}

// reconcilePackStatus applies nextPackStatus inside the pack's transaction.
// Call it after any change to the pack's issues or runs.
func reconcilePackStatus(ctx context.Context, tx *store.PackTx) error {
	current := tx.Pack().Status
	if current.Final() {
		return nil
	}
	succeeded, err := tx.HasSucceededRun(ctx)
	if err != nil {
		return err
	}
	open, err := tx.OpenIssueCount(ctx)
	if err != nil {
		return err
	}
	if next := nextPackStatus(current, succeeded, open); next != current {
		return tx.SetPackStatus(ctx, next)
	}
	return nil
}
