package server

import (
	"context"

	"connectrpc.com/connect"

	issuev1 "github.com/sektor-ai/material-review-starter/go/gen/issue/v1"
	"github.com/sektor-ai/material-review-starter/go/gen/issue/v1/issuev1connect"
	"github.com/sektor-ai/material-review-starter/go/internal/service"
)

type IssueHandler struct {
	issues *service.Issues
}

var _ issuev1connect.IssueServiceHandler = (*IssueHandler)(nil)

func (h *IssueHandler) ListIssues(ctx context.Context, req *connect.Request[issuev1.ListIssuesRequest]) (*connect.Response[issuev1.ListIssuesResponse], error) {
	issues, cursor, err := h.issues.List(ctx, req.Msg.GetPackId())
	if err != nil {
		return nil, toConnectError(err)
	}
	out := &issuev1.ListIssuesResponse{Issues: make([]*issuev1.Issue, 0, len(issues)), CursorSeq: cursor}
	for _, i := range issues {
		out.Issues = append(out.Issues, toProtoIssue(i))
	}
	return connect.NewResponse(out), nil
}

func (h *IssueHandler) GetIssue(ctx context.Context, req *connect.Request[issuev1.GetIssueRequest]) (*connect.Response[issuev1.GetIssueResponse], error) {
	issue, err := h.issues.Get(ctx, req.Msg.GetId())
	if err != nil {
		return nil, toConnectError(err)
	}
	return connect.NewResponse(&issuev1.GetIssueResponse{Issue: toProtoIssue(issue)}), nil
}

func (h *IssueHandler) CreateIssue(ctx context.Context, req *connect.Request[issuev1.CreateIssueRequest]) (*connect.Response[issuev1.CreateIssueResponse], error) {
	m := req.Msg
	issue, event, err := h.issues.Create(ctx, actor(ctx), service.CreateIssueInput{
		DocumentID:  m.GetDocumentId(),
		Severity:    severityFromProto[m.GetSeverity()],
		Title:       m.GetTitle(),
		Description: m.GetDescription(),
		Spec:        fromProtoSpec(m.GetSpecRef()),
		Evidence:    m.GetEvidence(),
		Note:        m.GetNote(),
	})
	if err != nil {
		return nil, toConnectError(err)
	}
	return connect.NewResponse(&issuev1.CreateIssueResponse{Issue: toProtoIssue(issue), Event: toProtoEvent(event)}), nil
}

func (h *IssueHandler) UpdateIssue(ctx context.Context, req *connect.Request[issuev1.UpdateIssueRequest]) (*connect.Response[issuev1.UpdateIssueResponse], error) {
	m := req.Msg
	in := service.UpdateIssueInput{
		ID:              m.GetId(),
		ExpectedVersion: m.GetExpectedVersion(),
		Title:           m.Title,
		Description:     m.Description,
		Evidence:        m.Evidence,
		Note:            m.GetNote(),
	}
	// An UNSPECIFIED enum maps to "", which validation rejects.
	if m.Status != nil {
		s := issueStatusFromProto[m.GetStatus()]
		in.Status = &s
	}
	if m.Severity != nil {
		s := severityFromProto[m.GetSeverity()]
		in.Severity = &s
	}
	if m.SpecRef != nil {
		spec := fromProtoSpec(m.SpecRef)
		in.Spec = &spec
	}
	issue, event, err := h.issues.Update(ctx, actor(ctx), in)
	if err != nil {
		return nil, toConnectError(err)
	}
	out := &issuev1.UpdateIssueResponse{Issue: toProtoIssue(issue)}
	if event != nil {
		out.Event = toProtoEvent(*event)
	}
	return connect.NewResponse(out), nil
}

func (h *IssueHandler) ListIssueEvents(ctx context.Context, req *connect.Request[issuev1.ListIssueEventsRequest]) (*connect.Response[issuev1.ListIssueEventsResponse], error) {
	events, err := h.issues.Events(ctx, req.Msg.GetIssueId())
	if err != nil {
		return nil, toConnectError(err)
	}
	out := &issuev1.ListIssueEventsResponse{Events: make([]*issuev1.IssueEvent, 0, len(events))}
	for _, e := range events {
		out.Events = append(out.Events, toProtoEvent(e))
	}
	return connect.NewResponse(out), nil
}
