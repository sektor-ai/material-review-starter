package store

import (
	"errors"
	"fmt"
	"time"
)

var (
	// ErrAlreadyExists: a unique value (e.g. a pack's submittal number) is taken.
	ErrAlreadyExists = errors.New("already exists")
	// ErrRunActive: the pack already has a queued or running review.
	ErrRunActive = errors.New("pack already has an active review run")
)

type PackStatus string

const (
	PackOpen      PackStatus = "open"
	PackResolved  PackStatus = "resolved"
	PackApproved  PackStatus = "approved"
	PackCancelled PackStatus = "cancelled"
)

// Final reports whether the pack can no longer change.
func (s PackStatus) Final() bool { return s == PackApproved || s == PackCancelled }

type Pack struct {
	ID           string
	SubmittalNo  string
	Title        string
	DesignBasis  string
	Status       PackStatus
	CreatedBy    User
	CreatedAt    time.Time
	UpdatedAt    time.Time
	ApprovedBy   *User
	ApprovedAt   *time.Time
	CancelledBy  *User
	CancelledAt  *time.Time
	CancelReason string

	DocumentCount  int
	OpenIssueCount int
}

type DocumentStatus string

const (
	DocumentProcessing DocumentStatus = "processing"
	DocumentReady      DocumentStatus = "ready"
	DocumentFailed     DocumentStatus = "failed"
)

type Document struct {
	ID         string
	PackID     string
	Filename   string
	Title      string
	MimeType   string
	SizeBytes  int64
	SHA256     []byte
	StorageKey string
	Status     DocumentStatus
	ParseError string
	CreatedBy  User
	CreatedAt  time.Time
}

type RunStatus string

const (
	RunQueued    RunStatus = "queued"
	RunRunning   RunStatus = "running"
	RunSucceeded RunStatus = "succeeded"
	RunFailed    RunStatus = "failed"
	RunCancelled RunStatus = "cancelled"
)

// Active reports whether the run is queued or running.
func (s RunStatus) Active() bool { return s == RunQueued || s == RunRunning }

type ReviewRun struct {
	ID             string
	PackID         string
	Status         RunStatus
	StartedBy      User
	Instructions   string
	AgentSessionID string
	ProgressNote   string
	IssuesCreated  int
	Summary        string
	Error          string
	CreatedAt      time.Time
	StartedAt      *time.Time
	FinishedAt     *time.Time
}

type IssueStatus string

const (
	IssueOpen   IssueStatus = "open"
	IssueClosed IssueStatus = "closed"
)

type IssueSeverity string

const (
	SeverityCritical IssueSeverity = "critical"
	SeverityMajor    IssueSeverity = "major"
	SeverityMinor    IssueSeverity = "minor"
)

// SpecRef is the QCS 2014 clause an issue breaks. The JSON form is what
// issue_events.changes records for the spec_ref field.
type SpecRef struct {
	Section     string `json:"section"`
	Part        string `json:"part"`
	Clause      string `json:"clause"`
	ClauseTitle string `json:"clause_title"`
	PDFPage     *int32 `json:"pdf_page"`
}

// Equal compares by value, including PDFPage.
func (s SpecRef) Equal(o SpecRef) bool {
	if s.Section != o.Section || s.Part != o.Part || s.Clause != o.Clause || s.ClauseTitle != o.ClauseTitle {
		return false
	}
	if s.PDFPage == nil || o.PDFPage == nil {
		return s.PDFPage == nil && o.PDFPage == nil
	}
	return *s.PDFPage == *o.PDFPage
}

// Issue is an issue's current state plus who created and last changed it,
// read from its version-1 and current-version events.
type Issue struct {
	ID          string
	PackID      string
	DocumentID  string
	Version     int32
	Status      IssueStatus
	Severity    IssueSeverity
	Title       string
	Description string
	Spec        SpecRef
	Evidence    string
	Metadata    map[string]any

	// Read only; empty on an Issue passed to InsertIssue or UpdateIssue.
	CreatedBy User
	CreatedAt time.Time
	UpdatedBy User
	UpdatedAt time.Time
	RunID     *string
}

type EventKind string

const (
	EventCreated EventKind = "created"
	EventUpdated EventKind = "updated"
)

// FieldChange is one entry of issue_events.changes. Field names follow
// issue.v1.Issue; enum values are the lower-case database values.
type FieldChange struct {
	Field string `json:"field"`
	Old   any    `json:"old"`
	New   any    `json:"new"`
}

type IssueEvent struct {
	Seq       int64
	IssueID   string
	PackID    string
	Version   int32
	Kind      EventKind
	Actor     User
	RunID     *string
	Note      string
	Changes   []FieldChange
	CreatedAt time.Time
}

// userJSON selects the auth.users row aliased a as a jsonb object that scans
// into User, or NULL (scanning into *User) when the row is missing.
func userJSON(a string) string {
	return fmt.Sprintf(`CASE WHEN %[1]s.id IS NULL THEN NULL ELSE jsonb_build_object(
		'id', %[1]s.id, 'name', %[1]s.name, 'email', coalesce(%[1]s.email, ''), 'kind', %[1]s.kind) END`, a)
}
