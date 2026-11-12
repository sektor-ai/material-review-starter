package service

import (
	"context"
	"strings"

	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

// Issues manages the shared issue table. Every write appends the issue's
// event in the same transaction, under the pack lock.
type Issues struct {
	st *store.Store
}

func NewIssues(st *store.Store) *Issues { return &Issues{st: st} }

// List returns a pack's issues and the event cursor to watch from.
func (s *Issues) List(ctx context.Context, packID string) ([]store.Issue, int64, error) {
	if err := checkID("pack_id", packID); err != nil {
		return nil, 0, err
	}
	if _, err := s.st.GetPack(ctx, packID); err != nil {
		return nil, 0, notFoundAs(err, "pack")
	}
	return s.st.IssuesSnapshot(ctx, packID)
}

func (s *Issues) Get(ctx context.Context, id string) (store.Issue, error) {
	if err := checkID("id", id); err != nil {
		return store.Issue{}, err
	}
	issue, err := s.st.GetIssue(ctx, id)
	return issue, notFoundAs(err, "issue")
}

func (s *Issues) Events(ctx context.Context, issueID string) ([]store.IssueEvent, error) {
	if _, err := s.Get(ctx, issueID); err != nil {
		return nil, err
	}
	return s.st.IssueEvents(ctx, issueID)
}

type CreateIssueInput struct {
	DocumentID  string
	Severity    store.IssueSeverity
	Title       string
	Description string
	Spec        store.SpecRef
	Evidence    string
	Note        string
	// Only from the agent.
	Metadata map[string]any
}

// Create adds an issue by hand.
func (s *Issues) Create(ctx context.Context, actor store.User, in CreateIssueInput) (store.Issue, store.IssueEvent, error) {
	in.Metadata = nil
	return s.create(ctx, actor, nil, in)
}

// RecordForRun adds an issue the agent reported during a review run. It
// fails with a PreconditionError once the run is no longer running.
func (s *Issues) RecordForRun(ctx context.Context, runID string, in CreateIssueInput) (store.Issue, error) {
	issue, _, err := s.create(ctx, store.User{ID: store.AgentUserID}, &runID, in)
	return issue, err
}

func (s *Issues) create(ctx context.Context, actor store.User, runID *string, in CreateIssueInput) (store.Issue, store.IssueEvent, error) {
	if err := checkID("document_id", in.DocumentID); err != nil {
		return store.Issue{}, store.IssueEvent{}, err
	}
	issue := store.Issue{
		DocumentID:  in.DocumentID,
		Version:     1,
		Status:      store.IssueOpen,
		Severity:    in.Severity,
		Title:       strings.TrimSpace(in.Title),
		Description: strings.TrimSpace(in.Description),
		Spec:        trimSpec(in.Spec),
		Evidence:    strings.TrimSpace(in.Evidence),
		Metadata:    in.Metadata,
	}
	if err := validateIssue(issue); err != nil {
		return store.Issue{}, store.IssueEvent{}, err
	}
	packID, err := s.st.PackIDOf(ctx, "documents", in.DocumentID)
	if err != nil {
		return store.Issue{}, store.IssueEvent{}, notFoundAs(err, "document")
	}

	var out store.Issue
	var event store.IssueEvent
	err = s.st.InPack(ctx, packID, func(tx *store.PackTx) error {
		if err := packFinal(tx.Pack()); err != nil {
			return err
		}
		if runID != nil {
			running, err := tx.CountRunIssue(ctx, *runID)
			if err != nil {
				return err
			}
			if !running {
				return precondition("review run %s is no longer running", *runID)
			}
		}
		id, err := tx.InsertIssue(ctx, issue)
		if err != nil {
			return err
		}
		issue.ID = id
		event, err = tx.AppendIssueEvent(ctx, store.IssueEvent{
			IssueID: id, Version: 1, Kind: store.EventCreated, Actor: actor, RunID: runID,
			Note: strings.TrimSpace(in.Note), Changes: creationChanges(issue),
		})
		if err != nil {
			return err
		}
		if err := reconcilePackStatus(ctx, tx); err != nil {
			return err
		}
		out, err = tx.Issue(ctx, id)
		return err
	})
	return out, event, err
}

type UpdateIssueInput struct {
	ID              string
	ExpectedVersion int32
	Status          *store.IssueStatus
	Severity        *store.IssueSeverity
	Title           *string
	Description     *string
	Spec            *store.SpecRef
	Evidence        *string
	// Recorded on the event. Dropped if nothing else changes.
	Note string
}

// Update applies the set fields if ExpectedVersion is current. It returns
// a *ConflictError otherwise, and a nil event when nothing changed.
func (s *Issues) Update(ctx context.Context, actor store.User, in UpdateIssueInput) (store.Issue, *store.IssueEvent, error) {
	if err := checkID("id", in.ID); err != nil {
		return store.Issue{}, nil, err
	}
	if in.ExpectedVersion < 1 {
		return store.Issue{}, nil, invalid("expected_version is required")
	}
	packID, err := s.st.PackIDOf(ctx, "issues", in.ID)
	if err != nil {
		return store.Issue{}, nil, notFoundAs(err, "issue")
	}

	var out store.Issue
	var event *store.IssueEvent
	err = s.st.InPack(ctx, packID, func(tx *store.PackTx) error {
		current, err := tx.Issue(ctx, in.ID)
		if err != nil {
			return err
		}
		if current.Version != in.ExpectedVersion {
			return &ConflictError{Current: current}
		}
		next, changes, err := applyUpdate(current, in)
		if err != nil {
			return err
		}
		if len(changes) == 0 {
			out = current
			return nil
		}
		if err := packFinal(tx.Pack()); err != nil {
			return err
		}
		if err := tx.UpdateIssue(ctx, next); err != nil {
			return err
		}
		ev, err := tx.AppendIssueEvent(ctx, store.IssueEvent{
			IssueID: next.ID, Version: next.Version, Kind: store.EventUpdated, Actor: actor,
			Note: strings.TrimSpace(in.Note), Changes: changes,
		})
		if err != nil {
			return err
		}
		event = &ev
		if err := reconcilePackStatus(ctx, tx); err != nil {
			return err
		}
		out, err = tx.Issue(ctx, next.ID)
		return err
	})
	return out, event, notFoundAs(err, "issue")
}

// applyUpdate returns the issue with in's set fields applied, version+1,
// and the changed fields in a fixed order. No changes: version unchanged.
func applyUpdate(current store.Issue, in UpdateIssueInput) (store.Issue, []store.FieldChange, error) {
	next := current
	var changes []store.FieldChange
	if in.Status != nil && *in.Status != current.Status {
		next.Status = *in.Status
		changes = append(changes, store.FieldChange{Field: "status", Old: string(current.Status), New: string(next.Status)})
	}
	if in.Severity != nil && *in.Severity != current.Severity {
		next.Severity = *in.Severity
		changes = append(changes, store.FieldChange{Field: "severity", Old: string(current.Severity), New: string(next.Severity)})
	}
	if in.Title != nil {
		if t := strings.TrimSpace(*in.Title); t != current.Title {
			next.Title = t
			changes = append(changes, store.FieldChange{Field: "title", Old: current.Title, New: t})
		}
	}
	if in.Description != nil {
		if d := strings.TrimSpace(*in.Description); d != current.Description {
			next.Description = d
			changes = append(changes, store.FieldChange{Field: "description", Old: current.Description, New: d})
		}
	}
	if in.Spec != nil {
		if spec := trimSpec(*in.Spec); !spec.Equal(current.Spec) {
			next.Spec = spec
			changes = append(changes, store.FieldChange{Field: "spec_ref", Old: current.Spec, New: spec})
		}
	}
	if in.Evidence != nil {
		if e := strings.TrimSpace(*in.Evidence); e != current.Evidence {
			next.Evidence = e
			changes = append(changes, store.FieldChange{Field: "evidence", Old: current.Evidence, New: e})
		}
	}
	if len(changes) == 0 {
		return current, nil, nil
	}
	if err := validateIssue(next); err != nil {
		return store.Issue{}, nil, err
	}
	next.Version = current.Version + 1
	return next, changes, nil
}

// creationChanges lists every initial value, for the version-1 event.
func creationChanges(i store.Issue) []store.FieldChange {
	return []store.FieldChange{
		{Field: "status", New: string(i.Status)},
		{Field: "severity", New: string(i.Severity)},
		{Field: "title", New: i.Title},
		{Field: "description", New: i.Description},
		{Field: "spec_ref", New: i.Spec},
		{Field: "evidence", New: i.Evidence},
	}
}

func validateIssue(i store.Issue) error {
	switch i.Status {
	case store.IssueOpen, store.IssueClosed:
	default:
		return invalid("status is required")
	}
	switch i.Severity {
	case store.SeverityCritical, store.SeverityMajor, store.SeverityMinor:
	default:
		return invalid("severity is required")
	}
	if i.Title == "" {
		return invalid("title is required")
	}
	if i.Spec.Section == "" || i.Spec.Part == "" || i.Spec.Clause == "" {
		return invalid("spec_ref needs section, part and clause")
	}
	if i.Spec.PDFPage != nil && *i.Spec.PDFPage < 1 {
		return invalid("spec_ref.pdf_page must be positive")
	}
	return nil
}

func trimSpec(s store.SpecRef) store.SpecRef {
	s.Section = strings.TrimSpace(s.Section)
	s.Part = strings.TrimSpace(s.Part)
	s.Clause = strings.TrimSpace(s.Clause)
	s.ClauseTitle = strings.TrimSpace(s.ClauseTitle)
	return s
}
