package server

import (
	"encoding/hex"
	"log/slog"
	"time"

	"google.golang.org/protobuf/types/known/structpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	authv1 "github.com/sektor-ai/material-review-starter/go/gen/auth/v1"
	issuev1 "github.com/sektor-ai/material-review-starter/go/gen/issue/v1"
	packv1 "github.com/sektor-ai/material-review-starter/go/gen/pack/v1"
	reviewv1 "github.com/sektor-ai/material-review-starter/go/gen/review/v1"
	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

// Enum mappings. Database values are lower-case; proto values are the
// generated constants. Unknown values map to UNSPECIFIED.

var userKinds = map[store.UserKind]authv1.UserKind{
	store.UserKindHuman: authv1.UserKind_USER_KIND_HUMAN,
	store.UserKindAgent: authv1.UserKind_USER_KIND_AGENT,
}

var packStatuses = map[store.PackStatus]packv1.PackStatus{
	store.PackOpen:      packv1.PackStatus_PACK_STATUS_OPEN,
	store.PackResolved:  packv1.PackStatus_PACK_STATUS_RESOLVED,
	store.PackApproved:  packv1.PackStatus_PACK_STATUS_APPROVED,
	store.PackCancelled: packv1.PackStatus_PACK_STATUS_CANCELLED,
}

var documentStatuses = map[store.DocumentStatus]packv1.DocumentStatus{
	store.DocumentProcessing: packv1.DocumentStatus_DOCUMENT_STATUS_PROCESSING,
	store.DocumentReady:      packv1.DocumentStatus_DOCUMENT_STATUS_READY,
	store.DocumentFailed:     packv1.DocumentStatus_DOCUMENT_STATUS_FAILED,
}

var runStatuses = map[store.RunStatus]reviewv1.ReviewRunStatus{
	store.RunQueued:    reviewv1.ReviewRunStatus_REVIEW_RUN_STATUS_QUEUED,
	store.RunRunning:   reviewv1.ReviewRunStatus_REVIEW_RUN_STATUS_RUNNING,
	store.RunSucceeded: reviewv1.ReviewRunStatus_REVIEW_RUN_STATUS_SUCCEEDED,
	store.RunFailed:    reviewv1.ReviewRunStatus_REVIEW_RUN_STATUS_FAILED,
	store.RunCancelled: reviewv1.ReviewRunStatus_REVIEW_RUN_STATUS_CANCELLED,
}

var issueStatuses = map[store.IssueStatus]issuev1.IssueStatus{
	store.IssueOpen:   issuev1.IssueStatus_ISSUE_STATUS_OPEN,
	store.IssueClosed: issuev1.IssueStatus_ISSUE_STATUS_CLOSED,
}

var severities = map[store.IssueSeverity]issuev1.IssueSeverity{
	store.SeverityCritical: issuev1.IssueSeverity_ISSUE_SEVERITY_CRITICAL,
	store.SeverityMajor:    issuev1.IssueSeverity_ISSUE_SEVERITY_MAJOR,
	store.SeverityMinor:    issuev1.IssueSeverity_ISSUE_SEVERITY_MINOR,
}

var eventKinds = map[store.EventKind]issuev1.IssueEventKind{
	store.EventCreated: issuev1.IssueEventKind_ISSUE_EVENT_KIND_CREATED,
	store.EventUpdated: issuev1.IssueEventKind_ISSUE_EVENT_KIND_UPDATED,
}

func reverse[K, V comparable](m map[K]V) map[V]K {
	out := make(map[V]K, len(m))
	for k, v := range m {
		out[v] = k
	}
	return out
}

var (
	issueStatusFromProto = reverse(issueStatuses)
	severityFromProto    = reverse(severities)
)

func ts(t time.Time) *timestamppb.Timestamp {
	if t.IsZero() {
		return nil
	}
	return timestamppb.New(t)
}

func tsPtr(t *time.Time) *timestamppb.Timestamp {
	if t == nil {
		return nil
	}
	return timestamppb.New(*t)
}

func toProtoUser(u store.User) *authv1.User {
	return &authv1.User{Id: u.ID, Name: u.Name, Email: u.Email, Kind: userKinds[u.Kind]}
}

func toProtoUserPtr(u *store.User) *authv1.User {
	if u == nil {
		return nil
	}
	return toProtoUser(*u)
}

func toProtoPack(p store.Pack) *packv1.Pack {
	return &packv1.Pack{
		Id:             p.ID,
		SubmittalNo:    p.SubmittalNo,
		Title:          p.Title,
		DesignBasis:    p.DesignBasis,
		Status:         packStatuses[p.Status],
		CreatedBy:      toProtoUser(p.CreatedBy),
		CreatedAt:      ts(p.CreatedAt),
		UpdatedAt:      ts(p.UpdatedAt),
		ApprovedBy:     toProtoUserPtr(p.ApprovedBy),
		ApprovedAt:     tsPtr(p.ApprovedAt),
		DocumentCount:  int32(p.DocumentCount),
		OpenIssueCount: int32(p.OpenIssueCount),
		CancelledBy:    toProtoUserPtr(p.CancelledBy),
		CancelledAt:    tsPtr(p.CancelledAt),
		CancelReason:   p.CancelReason,
	}
}

func toProtoDocument(d store.Document) *packv1.Document {
	return &packv1.Document{
		Id:         d.ID,
		PackId:     d.PackID,
		Filename:   d.Filename,
		Title:      d.Title,
		MimeType:   d.MimeType,
		SizeBytes:  d.SizeBytes,
		Sha256:     hex.EncodeToString(d.SHA256),
		Status:     documentStatuses[d.Status],
		ParseError: d.ParseError,
		CreatedBy:  toProtoUser(d.CreatedBy),
		CreatedAt:  ts(d.CreatedAt),
	}
}

func toProtoRun(r store.ReviewRun) *reviewv1.ReviewRun {
	return &reviewv1.ReviewRun{
		Id:             r.ID,
		PackId:         r.PackID,
		Status:         runStatuses[r.Status],
		StartedBy:      toProtoUser(r.StartedBy),
		CreatedAt:      ts(r.CreatedAt),
		StartedAt:      tsPtr(r.StartedAt),
		FinishedAt:     tsPtr(r.FinishedAt),
		AgentSessionId: r.AgentSessionID,
		ProgressNote:   r.ProgressNote,
		IssuesCreated:  int32(r.IssuesCreated),
		Summary:        r.Summary,
		Error:          r.Error,
	}
}

func toProtoRunPtr(r *store.ReviewRun) *reviewv1.ReviewRun {
	if r == nil {
		return nil
	}
	return toProtoRun(*r)
}

func toProtoSpec(s store.SpecRef) *issuev1.SpecReference {
	return &issuev1.SpecReference{
		Section: s.Section, Part: s.Part, Clause: s.Clause, ClauseTitle: s.ClauseTitle, PdfPage: s.PDFPage,
	}
}

// fromProtoSpec tolerates a nil message (spec_ref not sent); validation
// then rejects the empty clause.
func fromProtoSpec(s *issuev1.SpecReference) store.SpecRef {
	out := store.SpecRef{
		Section: s.GetSection(), Part: s.GetPart(), Clause: s.GetClause(), ClauseTitle: s.GetClauseTitle(),
	}
	if s != nil && s.PdfPage != nil {
		page := s.GetPdfPage()
		out.PDFPage = &page
	}
	return out
}

func toProtoIssue(i store.Issue) *issuev1.Issue {
	out := &issuev1.Issue{
		Id:          i.ID,
		PackId:      i.PackID,
		DocumentId:  i.DocumentID,
		Version:     i.Version,
		Status:      issueStatuses[i.Status],
		Severity:    severities[i.Severity],
		Title:       i.Title,
		Description: i.Description,
		SpecRef:     toProtoSpec(i.Spec),
		Evidence:    i.Evidence,
		CreatedBy:   toProtoUser(i.CreatedBy),
		CreatedAt:   ts(i.CreatedAt),
		UpdatedBy:   toProtoUser(i.UpdatedBy),
		UpdatedAt:   ts(i.UpdatedAt),
		RunId:       i.RunID,
	}
	if len(i.Metadata) > 0 {
		md, err := structpb.NewStruct(i.Metadata)
		if err != nil {
			slog.Warn("dropping issue metadata that does not convert", "issue_id", i.ID, "err", err)
		} else {
			out.Metadata = md
		}
	}
	return out
}

func toProtoEvent(e store.IssueEvent) *issuev1.IssueEvent {
	changes := make([]*issuev1.FieldChange, 0, len(e.Changes))
	for _, c := range e.Changes {
		changes = append(changes, &issuev1.FieldChange{
			Field:    c.Field,
			OldValue: changeValue(c.Field, c.Old),
			NewValue: changeValue(c.Field, c.New),
		})
	}
	return &issuev1.IssueEvent{
		Seq:       e.Seq,
		IssueId:   e.IssueID,
		PackId:    e.PackID,
		Version:   e.Version,
		Kind:      eventKinds[e.Kind],
		Actor:     toProtoUser(e.Actor),
		RunId:     e.RunID,
		Note:      e.Note,
		Changes:   changes,
		CreatedAt: ts(e.CreatedAt),
	}
}

// changeValue renders a recorded change value as JSON for the API: enum
// fields use proto enum names, spec_ref is an object.
func changeValue(field string, v any) *structpb.Value {
	if v == nil {
		return structpb.NewNullValue()
	}
	if s, ok := v.(string); ok {
		switch field {
		case "status":
			return structpb.NewStringValue(issueStatuses[store.IssueStatus(s)].String())
		case "severity":
			return structpb.NewStringValue(severities[store.IssueSeverity(s)].String())
		}
	}
	// Values are read back from jsonb, so they are already plain JSON types.
	out, err := structpb.NewValue(v)
	if err != nil {
		slog.Warn("change value does not convert", "field", field, "err", err)
		return structpb.NewNullValue()
	}
	return out
}
