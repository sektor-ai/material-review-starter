package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// querier is satisfied by *pgxpool.Pool and pgx.Tx, so read queries run
// either standalone or inside a PackTx.
type querier interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ---- Selects ----------------------------------------------------------------

var packSelect = `SELECT p.id, p.submittal_no, p.title, p.design_basis, p.status::text,
	` + userJSON("cb") + `, p.created_at, p.updated_at,
	` + userJSON("ab") + `, p.approved_at,
	` + userJSON("xb") + `, p.cancelled_at, p.cancel_reason,
	(SELECT count(*) FROM documents d WHERE d.pack_id = p.id),
	(SELECT count(*) FROM issues i WHERE i.pack_id = p.id AND i.status = 'open')
  FROM packs p
  JOIN auth.users cb ON cb.id = p.created_by
  LEFT JOIN auth.users ab ON ab.id = p.approved_by
  LEFT JOIN auth.users xb ON xb.id = p.cancelled_by`

func scanPack(row pgx.Row) (Pack, error) {
	var p Pack
	err := row.Scan(&p.ID, &p.SubmittalNo, &p.Title, &p.DesignBasis, &p.Status,
		&p.CreatedBy, &p.CreatedAt, &p.UpdatedAt,
		&p.ApprovedBy, &p.ApprovedAt,
		&p.CancelledBy, &p.CancelledAt, &p.CancelReason,
		&p.DocumentCount, &p.OpenIssueCount)
	return p, err
}

var documentSelect = `SELECT d.id, d.pack_id, d.filename, d.title, d.mime_type, d.size_bytes, d.sha256,
	d.storage_key, d.status::text, d.parse_error, ` + userJSON("cb") + `, d.created_at
  FROM documents d JOIN auth.users cb ON cb.id = d.created_by`

func scanDocument(row pgx.Row) (Document, error) {
	var d Document
	err := row.Scan(&d.ID, &d.PackID, &d.Filename, &d.Title, &d.MimeType, &d.SizeBytes, &d.SHA256,
		&d.StorageKey, &d.Status, &d.ParseError, &d.CreatedBy, &d.CreatedAt)
	return d, err
}

var runSelect = `SELECT r.id, r.pack_id, r.status::text, ` + userJSON("sb") + `, r.instructions,
	coalesce(r.agent_session_id, ''), r.progress_note, r.issues_created, r.summary, r.error,
	r.created_at, r.started_at, r.finished_at
  FROM review_runs r JOIN auth.users sb ON sb.id = r.started_by`

func scanRun(row pgx.Row) (ReviewRun, error) {
	var r ReviewRun
	err := row.Scan(&r.ID, &r.PackID, &r.Status, &r.StartedBy, &r.Instructions,
		&r.AgentSessionID, &r.ProgressNote, &r.IssuesCreated, &r.Summary, &r.Error,
		&r.CreatedAt, &r.StartedAt, &r.FinishedAt)
	return r, err
}

// issueSelect joins the version-1 event (creator) and the current-version
// event (last change); both exist for every committed issue.
var issueSelect = `SELECT i.id, i.pack_id, i.document_id, i.version, i.status::text, i.severity::text,
	i.title, i.description, i.spec_section, i.spec_part, i.spec_clause, i.spec_clause_title,
	i.spec_pdf_page, i.evidence, i.metadata,
	` + userJSON("cu") + `, ce.created_at, ce.run_id,
	` + userJSON("uu") + `, ue.created_at
  FROM issues i
  JOIN issue_events ce ON ce.issue_id = i.id AND ce.version = 1
  JOIN auth.users cu ON cu.id = ce.actor_id
  JOIN issue_events ue ON ue.issue_id = i.id AND ue.version = i.version
  JOIN auth.users uu ON uu.id = ue.actor_id`

func scanIssue(row pgx.Row) (Issue, error) {
	var i Issue
	err := row.Scan(&i.ID, &i.PackID, &i.DocumentID, &i.Version, &i.Status, &i.Severity,
		&i.Title, &i.Description, &i.Spec.Section, &i.Spec.Part, &i.Spec.Clause, &i.Spec.ClauseTitle,
		&i.Spec.PDFPage, &i.Evidence, &i.Metadata,
		&i.CreatedBy, &i.CreatedAt, &i.RunID,
		&i.UpdatedBy, &i.UpdatedAt)
	return i, err
}

var eventSelect = `SELECT e.seq, e.issue_id, e.pack_id, e.version, e.kind::text, ` + userJSON("a") + `,
	e.run_id, e.note, e.changes, e.created_at
  FROM issue_events e JOIN auth.users a ON a.id = e.actor_id`

func scanEvent(row pgx.Row) (IssueEvent, error) {
	var e IssueEvent
	err := row.Scan(&e.Seq, &e.IssueID, &e.PackID, &e.Version, &e.Kind, &e.Actor,
		&e.RunID, &e.Note, &e.Changes, &e.CreatedAt)
	return e, err
}

func one[T any](ctx context.Context, q querier, scan func(pgx.Row) (T, error), what, sql string, args ...any) (T, error) {
	v, err := scan(q.QueryRow(ctx, sql, args...))
	if errors.Is(err, pgx.ErrNoRows) {
		return v, ErrNotFound
	}
	if err != nil {
		return v, fmt.Errorf("querying %s: %w", what, err)
	}
	return v, nil
}

func many[T any](ctx context.Context, q querier, scan func(pgx.Row) (T, error), what, sql string, args ...any) ([]T, error) {
	rows, err := q.Query(ctx, sql, args...)
	if err != nil {
		return nil, fmt.Errorf("querying %s: %w", what, err)
	}
	defer rows.Close()
	var out []T
	for rows.Next() {
		v, err := scan(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning %s: %w", what, err)
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading %s: %w", what, err)
	}
	return out, nil
}

func scalar[T any](ctx context.Context, q querier, what, sql string, args ...any) (T, error) {
	var v T
	err := q.QueryRow(ctx, sql, args...).Scan(&v)
	if errors.Is(err, pgx.ErrNoRows) {
		return v, ErrNotFound
	}
	if err != nil {
		return v, fmt.Errorf("querying %s: %w", what, err)
	}
	return v, nil
}

func uniqueViolation(err error, constraint string) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == constraint
}

// ---- Reads ------------------------------------------------------------------

func (s *Store) ListPacks(ctx context.Context) ([]Pack, error) {
	return many(ctx, s.pool, scanPack, "packs", packSelect+` ORDER BY p.created_at DESC`)
}

func (s *Store) GetPack(ctx context.Context, id string) (Pack, error) {
	return one(ctx, s.pool, scanPack, "pack", packSelect+` WHERE p.id = $1`, id)
}

func (s *Store) ListDocuments(ctx context.Context, packID string) ([]Document, error) {
	return many(ctx, s.pool, scanDocument, "documents", documentSelect+` WHERE d.pack_id = $1 ORDER BY d.created_at`, packID)
}

func (s *Store) GetDocument(ctx context.Context, id string) (Document, error) {
	return one(ctx, s.pool, scanDocument, "document", documentSelect+` WHERE d.id = $1`, id)
}

// ReadyDocuments returns a pack's READY documents with their parsed text.
func (s *Store) ReadyDocuments(ctx context.Context, packID string) ([]Document, []string, error) {
	docs, err := many(ctx, s.pool, scanDocument, "documents",
		documentSelect+` WHERE d.pack_id = $1 AND d.status = 'ready' ORDER BY d.created_at`, packID)
	if err != nil {
		return nil, nil, err
	}
	contents := make([]string, len(docs))
	for i, d := range docs {
		if contents[i], err = s.DocumentContent(ctx, d.ID); err != nil {
			return nil, nil, err
		}
	}
	return docs, contents, nil
}

// DocumentContent returns the parsed text, empty if not parsed.
func (s *Store) DocumentContent(ctx context.Context, id string) (string, error) {
	return scalar[string](ctx, s.pool, "document content", `SELECT coalesce(parsed_content, '') FROM documents WHERE id = $1`, id)
}

func (s *Store) GetRun(ctx context.Context, id string) (ReviewRun, error) {
	return one(ctx, s.pool, scanRun, "review run", runSelect+` WHERE r.id = $1`, id)
}

func (s *Store) ListRuns(ctx context.Context, packID string) ([]ReviewRun, error) {
	return many(ctx, s.pool, scanRun, "review runs", runSelect+` WHERE r.pack_id = $1 ORDER BY r.created_at DESC`, packID)
}

// LatestRun returns the pack's newest run, or ErrNotFound.
func (s *Store) LatestRun(ctx context.Context, packID string) (ReviewRun, error) {
	return one(ctx, s.pool, scanRun, "latest review run", runSelect+` WHERE r.pack_id = $1 ORDER BY r.created_at DESC LIMIT 1`, packID)
}

func (s *Store) GetIssue(ctx context.Context, id string) (Issue, error) {
	return one(ctx, s.pool, scanIssue, "issue", issueSelect+` WHERE i.id = $1`, id)
}

// IssuesByID returns the issues with the given ids, keyed by id.
func (s *Store) IssuesByID(ctx context.Context, ids []string) (map[string]Issue, error) {
	list, err := many(ctx, s.pool, scanIssue, "issues", issueSelect+` WHERE i.id = ANY($1::uuid[])`, ids)
	if err != nil {
		return nil, err
	}
	out := make(map[string]Issue, len(list))
	for _, i := range list {
		out[i.ID] = i
	}
	return out, nil
}

// IssuesSnapshot returns a pack's issues and the highest event seq of the
// pack, read in one snapshot so the seq is a valid WatchPack cursor.
func (s *Store) IssuesSnapshot(ctx context.Context, packID string) ([]Issue, int64, error) {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, 0, fmt.Errorf("beginning snapshot: %w", err)
	}
	defer tx.Rollback(ctx)
	issues, err := many(ctx, tx, scanIssue, "issues", issueSelect+` WHERE i.pack_id = $1 ORDER BY ce.created_at, i.id`, packID)
	if err != nil {
		return nil, 0, err
	}
	cursor, err := scalar[int64](ctx, tx, "event cursor", `SELECT coalesce(max(seq), 0) FROM issue_events WHERE pack_id = $1`, packID)
	if err != nil {
		return nil, 0, err
	}
	return issues, cursor, tx.Commit(ctx)
}

func (s *Store) IssueEvents(ctx context.Context, issueID string) ([]IssueEvent, error) {
	return many(ctx, s.pool, scanEvent, "issue events", eventSelect+` WHERE e.issue_id = $1 ORDER BY e.version`, issueID)
}

// IssueEventsAfter returns up to limit events of a pack with seq > after,
// in seq order.
func (s *Store) IssueEventsAfter(ctx context.Context, packID string, after int64, limit int) ([]IssueEvent, error) {
	return many(ctx, s.pool, scanEvent, "issue events",
		eventSelect+` WHERE e.pack_id = $1 AND e.seq > $2 ORDER BY e.seq LIMIT $3`, packID, after, limit)
}

// PackIDOf returns the pack of an issue, document or review run (table is
// "issues", "documents" or "review_runs"), or ErrNotFound.
func (s *Store) PackIDOf(ctx context.Context, table, id string) (string, error) {
	switch table {
	case "issues", "documents", "review_runs":
	default:
		return "", fmt.Errorf("PackIDOf: unexpected table %q", table)
	}
	return scalar[string](ctx, s.pool, "pack id", `SELECT pack_id FROM `+table+` WHERE id = $1`, id)
}

// ---- Writes outside a pack lock -------------------------------------------------

type NewPack struct {
	SubmittalNo string
	Title       string
	DesignBasis string
	CreatedBy   string
}

func (s *Store) CreatePack(ctx context.Context, p NewPack) (Pack, error) {
	var id string
	err := s.pool.QueryRow(ctx,
		`INSERT INTO packs (submittal_no, title, design_basis, created_by) VALUES ($1, $2, $3, $4) RETURNING id`,
		p.SubmittalNo, p.Title, p.DesignBasis, p.CreatedBy).Scan(&id)
	if uniqueViolation(err, "packs_submittal_no_key") {
		return Pack{}, ErrAlreadyExists
	}
	if err != nil {
		return Pack{}, fmt.Errorf("inserting pack: %w", err)
	}
	return s.GetPack(ctx, id)
}

// ClaimRun takes the oldest queued run, or a running one whose lease has
// expired, marks it running under owner, and returns it. ErrNotFound if
// there is nothing to do.
func (s *Store) ClaimRun(ctx context.Context, owner string, lease time.Duration) (ReviewRun, error) {
	var id string
	err := s.pool.QueryRow(ctx, `
		UPDATE review_runs
		   SET status = 'running', started_at = coalesce(started_at, now()),
		       lease_owner = $1, lease_expires_at = now() + make_interval(secs => $2)
		 WHERE id = (SELECT id FROM review_runs
		              WHERE status = 'queued' OR (status = 'running' AND lease_expires_at < now())
		              ORDER BY created_at
		              FOR UPDATE SKIP LOCKED
		              LIMIT 1)
		RETURNING id`, owner, lease.Seconds()).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return ReviewRun{}, ErrNotFound
	}
	if err != nil {
		return ReviewRun{}, fmt.Errorf("claiming review run: %w", err)
	}
	return s.GetRun(ctx, id)
}

// RenewLease extends owner's lease on a running run. It returns false when
// the run is no longer running under owner (cancelled, or taken over).
func (s *Store) RenewLease(ctx context.Context, runID, owner string, lease time.Duration) (bool, error) {
	tag, err := s.pool.Exec(ctx, `
		UPDATE review_runs SET lease_expires_at = now() + make_interval(secs => $3)
		 WHERE id = $1 AND status = 'running' AND lease_owner = $2`, runID, owner, lease.Seconds())
	if err != nil {
		return false, fmt.Errorf("renewing lease: %w", err)
	}
	return tag.RowsAffected() == 1, nil
}

// SetRunProgress updates the progress note (and the agent session id, if
// set) of a run owned by owner.
func (s *Store) SetRunProgress(ctx context.Context, runID, owner, note, sessionID string) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE review_runs
		   SET progress_note = $3, agent_session_id = coalesce(nullif($4, ''), agent_session_id)
		 WHERE id = $1 AND status = 'running' AND lease_owner = $2`, runID, owner, note, sessionID)
	if err != nil {
		return fmt.Errorf("updating run progress: %w", err)
	}
	return nil
}

// notifyPack sends a pack_activity notification for a change the database
// triggers do not cover (a new document changes the pack's counts).
func notifyPack(ctx context.Context, q querier, packID string) error {
	_, err := q.Exec(ctx, `SELECT pg_notify('pack_activity', jsonb_build_object('pack_id', $1::text, 'kind', 'pack')::text)`, packID)
	if err != nil {
		return fmt.Errorf("notifying pack activity: %w", err)
	}
	return nil
}
