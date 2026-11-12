package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// PackTx is a transaction holding the row lock of one pack. Every write that
// touches a pack's issues, runs or status goes through one, which serialises
// writers per pack: issue_events.seq is then in commit order within a pack,
// and status checks cannot race.
type PackTx struct {
	tx   pgx.Tx
	pack Pack
}

// InPack locks the pack row, runs fn, and commits if fn returns nil.
// ErrNotFound if the pack does not exist.
func (s *Store) InPack(ctx context.Context, packID string, fn func(*PackTx) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("beginning transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	if _, err := scalar[int](tx, ctx, "pack lock", `SELECT 1 FROM packs WHERE id = $1 FOR UPDATE`, packID); err != nil {
		return err
	}
	pack, err := one(tx, ctx, scanPack, "pack", packSelect+` WHERE p.id = $1`, packID)
	if err != nil {
		return err
	}
	if err := fn(&PackTx{tx: tx, pack: pack}); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("committing: %w", err)
	}
	return nil
}

// Pack is the pack as read when the lock was taken.
func (t *PackTx) Pack() Pack { return t.pack }

// ReloadPack re-reads the pack, including writes made in this transaction.
func (t *PackTx) ReloadPack(ctx context.Context) (Pack, error) {
	return one(t.tx, ctx, scanPack, "pack", packSelect+` WHERE p.id = $1`, t.pack.ID)
}

func (t *PackTx) UpdatePackDetails(ctx context.Context, title, designBasis *string) error {
	_, err := t.tx.Exec(ctx, `
		UPDATE packs SET title = coalesce($2, title), design_basis = coalesce($3, design_basis)
		 WHERE id = $1`, t.pack.ID, title, designBasis)
	if err != nil {
		return fmt.Errorf("updating pack: %w", err)
	}
	return nil
}

// SetPackStatus moves the pack between open and resolved.
func (t *PackTx) SetPackStatus(ctx context.Context, status PackStatus) error {
	if status != PackOpen && status != PackResolved {
		return fmt.Errorf("SetPackStatus: %q is set by Approve or Cancel", status)
	}
	if _, err := t.tx.Exec(ctx, `UPDATE packs SET status = $2::text::pack_status WHERE id = $1`, t.pack.ID, string(status)); err != nil {
		return fmt.Errorf("setting pack status: %w", err)
	}
	return nil
}

func (t *PackTx) ApprovePack(ctx context.Context, by string) error {
	_, err := t.tx.Exec(ctx, `
		UPDATE packs SET status = 'approved', approved_by = $2, approved_at = now() WHERE id = $1`, t.pack.ID, by)
	if err != nil {
		return fmt.Errorf("approving pack: %w", err)
	}
	return nil
}

func (t *PackTx) CancelPack(ctx context.Context, by, reason string) error {
	_, err := t.tx.Exec(ctx, `
		UPDATE packs SET status = 'cancelled', cancelled_by = $2, cancelled_at = now(), cancel_reason = $3
		 WHERE id = $1`, t.pack.ID, by, reason)
	if err != nil {
		return fmt.Errorf("cancelling pack: %w", err)
	}
	return nil
}

// NotifyPack tells watchers the pack changed in a way no trigger reports.
func (t *PackTx) NotifyPack(ctx context.Context) error { return notifyPack(ctx, t.tx, t.pack.ID) }

// ---- Documents -----------------------------------------------------------------

type NewDocument struct {
	ID         string
	Filename   string
	Title      string
	MimeType   string
	SizeBytes  int64
	SHA256     []byte
	StorageKey string
	Status     DocumentStatus
	ParseError string
	Content    *string
	CreatedBy  string
}

func (t *PackTx) InsertDocument(ctx context.Context, d NewDocument) (Document, error) {
	_, err := t.tx.Exec(ctx, `
		INSERT INTO documents (id, pack_id, filename, title, mime_type, size_bytes, sha256, storage_key,
		                       status, parse_error, parsed_content, created_by)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::text::document_status, $10, $11, $12)`,
		d.ID, t.pack.ID, d.Filename, d.Title, d.MimeType, d.SizeBytes, d.SHA256, d.StorageKey,
		string(d.Status), d.ParseError, d.Content, d.CreatedBy)
	if err != nil {
		return Document{}, fmt.Errorf("inserting document: %w", err)
	}
	return one(t.tx, ctx, scanDocument, "document", documentSelect+` WHERE d.id = $1`, d.ID)
}

// DocumentInPack returns a document of this pack, or ErrNotFound.
func (t *PackTx) DocumentInPack(ctx context.Context, id string) (Document, error) {
	return one(t.tx, ctx, scanDocument, "document", documentSelect+` WHERE d.id = $1 AND d.pack_id = $2`, id, t.pack.ID)
}

// ReadyDocumentCount counts the pack's READY documents.
func (t *PackTx) ReadyDocumentCount(ctx context.Context) (int, error) {
	return scalar[int](t.tx, ctx, "ready documents",
		`SELECT count(*) FROM documents WHERE pack_id = $1 AND status = 'ready'`, t.pack.ID)
}

// ---- Issues ----------------------------------------------------------------------

// Issue returns an issue of this pack, or ErrNotFound.
func (t *PackTx) Issue(ctx context.Context, id string) (Issue, error) {
	return one(t.tx, ctx, scanIssue, "issue", issueSelect+` WHERE i.id = $1 AND i.pack_id = $2`, id, t.pack.ID)
}

// InsertIssue inserts a new issue at version 1 and returns its id. The
// version-1 event must be appended in the same transaction.
func (t *PackTx) InsertIssue(ctx context.Context, i Issue) (string, error) {
	metadata := i.Metadata
	if metadata == nil {
		metadata = map[string]any{}
	}
	var id string
	err := t.tx.QueryRow(ctx, `
		INSERT INTO issues (pack_id, document_id, version, status, severity, title, description,
		                    spec_section, spec_part, spec_clause, spec_clause_title, spec_pdf_page,
		                    evidence, metadata)
		VALUES ($1, $2, 1, $3::text::issue_status, $4::text::issue_severity, $5, $6, $7, $8, $9, $10, $11, $12, $13)
		RETURNING id`,
		t.pack.ID, i.DocumentID, string(i.Status), string(i.Severity), i.Title, i.Description,
		i.Spec.Section, i.Spec.Part, i.Spec.Clause, i.Spec.ClauseTitle, i.Spec.PDFPage,
		i.Evidence, metadata).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("inserting issue: %w", err)
	}
	return id, nil
}

// UpdateIssue writes i's mutable fields and version. The database requires
// version to be the stored version + 1, and an event for it at commit.
func (t *PackTx) UpdateIssue(ctx context.Context, i Issue) error {
	tag, err := t.tx.Exec(ctx, `
		UPDATE issues
		   SET version = $3, status = $4::text::issue_status, severity = $5::text::issue_severity,
		       title = $6, description = $7, spec_section = $8, spec_part = $9, spec_clause = $10,
		       spec_clause_title = $11, spec_pdf_page = $12, evidence = $13
		 WHERE id = $1 AND pack_id = $2`,
		i.ID, t.pack.ID, i.Version, string(i.Status), string(i.Severity), i.Title, i.Description,
		i.Spec.Section, i.Spec.Part, i.Spec.Clause, i.Spec.ClauseTitle, i.Spec.PDFPage, i.Evidence)
	if err != nil {
		return fmt.Errorf("updating issue: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// AppendIssueEvent records an event (Seq, Actor other than its ID, and
// CreatedAt are ignored) and returns it as stored.
func (t *PackTx) AppendIssueEvent(ctx context.Context, e IssueEvent) (IssueEvent, error) {
	changes := e.Changes
	if changes == nil {
		changes = []FieldChange{}
	}
	var seq int64
	err := t.tx.QueryRow(ctx, `
		INSERT INTO issue_events (issue_id, pack_id, version, kind, actor_id, run_id, note, changes)
		VALUES ($1, $2, $3, $4::text::issue_event_kind, $5, $6, $7, $8)
		RETURNING seq`,
		e.IssueID, t.pack.ID, e.Version, string(e.Kind), e.Actor.ID, e.RunID, e.Note, changes).Scan(&seq)
	if err != nil {
		return IssueEvent{}, fmt.Errorf("appending issue event: %w", err)
	}
	return one(t.tx, ctx, scanEvent, "issue event", eventSelect+` WHERE e.seq = $1`, seq)
}

func (t *PackTx) OpenIssueCount(ctx context.Context) (int, error) {
	return scalar[int](t.tx, ctx, "open issues",
		`SELECT count(*) FROM issues WHERE pack_id = $1 AND status = 'open'`, t.pack.ID)
}

// ---- Review runs -------------------------------------------------------------------

func (t *PackTx) HasSucceededRun(ctx context.Context) (bool, error) {
	return scalar[bool](t.tx, ctx, "succeeded runs",
		`SELECT EXISTS (SELECT 1 FROM review_runs WHERE pack_id = $1 AND status = 'succeeded')`, t.pack.ID)
}

// ActiveRun returns the pack's queued or running run, or ErrNotFound.
func (t *PackTx) ActiveRun(ctx context.Context) (ReviewRun, error) {
	return one(t.tx, ctx, scanRun, "active run",
		runSelect+` WHERE r.pack_id = $1 AND r.status IN ('queued', 'running')`, t.pack.ID)
}

// Run returns a run of this pack, or ErrNotFound.
func (t *PackTx) Run(ctx context.Context, id string) (ReviewRun, error) {
	return one(t.tx, ctx, scanRun, "review run", runSelect+` WHERE r.id = $1 AND r.pack_id = $2`, id, t.pack.ID)
}

// InsertRun queues a review run. ErrRunActive if one is already active.
func (t *PackTx) InsertRun(ctx context.Context, startedBy, instructions string) (ReviewRun, error) {
	var id string
	err := t.tx.QueryRow(ctx, `
		INSERT INTO review_runs (pack_id, started_by, instructions) VALUES ($1, $2, $3) RETURNING id`,
		t.pack.ID, startedBy, instructions).Scan(&id)
	if uniqueViolation(err, "review_runs_one_active_per_pack") {
		return ReviewRun{}, ErrRunActive
	}
	if err != nil {
		return ReviewRun{}, fmt.Errorf("inserting review run: %w", err)
	}
	return t.Run(ctx, id)
}

// CancelActiveRuns cancels the pack's queued or running run, if any.
func (t *PackTx) CancelActiveRuns(ctx context.Context) error {
	_, err := t.tx.Exec(ctx, `
		UPDATE review_runs SET status = 'cancelled', finished_at = now(), lease_owner = NULL, lease_expires_at = NULL
		 WHERE pack_id = $1 AND status IN ('queued', 'running')`, t.pack.ID)
	if err != nil {
		return fmt.Errorf("cancelling review runs: %w", err)
	}
	return nil
}

// FinishRun records the outcome of a run owned by owner. It returns false
// when the run is no longer running under owner (it was cancelled).
func (t *PackTx) FinishRun(ctx context.Context, runID, owner string, status RunStatus, summary, errMsg string) (bool, error) {
	if status != RunSucceeded && status != RunFailed {
		return false, fmt.Errorf("FinishRun: unexpected status %q", status)
	}
	tag, err := t.tx.Exec(ctx, `
		UPDATE review_runs
		   SET status = $4::text::review_run_status, summary = $5, error = $6, finished_at = now(),
		       progress_note = '', lease_owner = NULL, lease_expires_at = NULL
		 WHERE id = $1 AND pack_id = $2 AND status = 'running' AND lease_owner = $3`,
		runID, t.pack.ID, owner, string(status), summary, errMsg)
	if err != nil {
		return false, fmt.Errorf("finishing review run: %w", err)
	}
	return tag.RowsAffected() == 1, nil
}

// CountRunIssue adds one to a running run's issues_created. It returns false
// when the run is not running (cancelled, or finished).
func (t *PackTx) CountRunIssue(ctx context.Context, runID string) (bool, error) {
	tag, err := t.tx.Exec(ctx, `
		UPDATE review_runs SET issues_created = issues_created + 1
		 WHERE id = $1 AND pack_id = $2 AND status = 'running'`, runID, t.pack.ID)
	if err != nil {
		return false, fmt.Errorf("counting run issue: %w", err)
	}
	return tag.RowsAffected() == 1, nil
}
