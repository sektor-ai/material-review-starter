package server

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"connectrpc.com/connect"

	issuev1 "github.com/sektor-ai/material-review-starter/go/gen/issue/v1"
	packv1 "github.com/sektor-ai/material-review-starter/go/gen/pack/v1"
	"github.com/sektor-ai/material-review-starter/go/gen/pack/v1/packv1connect"
	"github.com/sektor-ai/material-review-starter/go/internal/service"
	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

const (
	heartbeatInterval = 15 * time.Second
	replayBatch       = 200
)

type PackHandler struct {
	packs  *service.Packs
	docs   *service.Documents
	issues *service.Issues
	hub    *service.Hub
	st     *store.Store
}

var _ packv1connect.PackServiceHandler = (*PackHandler)(nil)

func (h *PackHandler) CreatePack(ctx context.Context, req *connect.Request[packv1.CreatePackRequest]) (*connect.Response[packv1.CreatePackResponse], error) {
	m := req.Msg
	pack, err := h.packs.Create(ctx, actor(ctx), service.CreatePackInput{
		SubmittalNo: m.GetSubmittalNo(), Title: m.GetTitle(), DesignBasis: m.GetDesignBasis(),
	})
	if err != nil {
		return nil, toConnectError(err)
	}
	return connect.NewResponse(&packv1.CreatePackResponse{Pack: toProtoPack(pack)}), nil
}

func (h *PackHandler) ListPacks(ctx context.Context, _ *connect.Request[packv1.ListPacksRequest]) (*connect.Response[packv1.ListPacksResponse], error) {
	packs, err := h.packs.List(ctx)
	if err != nil {
		return nil, toConnectError(err)
	}
	out := &packv1.ListPacksResponse{Packs: make([]*packv1.Pack, 0, len(packs))}
	for _, p := range packs {
		out.Packs = append(out.Packs, toProtoPack(p))
	}
	return connect.NewResponse(out), nil
}

func (h *PackHandler) GetPack(ctx context.Context, req *connect.Request[packv1.GetPackRequest]) (*connect.Response[packv1.GetPackResponse], error) {
	pack, docs, run, err := h.packs.Get(ctx, req.Msg.GetId())
	if err != nil {
		return nil, toConnectError(err)
	}
	out := &packv1.GetPackResponse{Pack: toProtoPack(pack), LatestRun: toProtoRunPtr(run)}
	for _, d := range docs {
		out.Documents = append(out.Documents, toProtoDocument(d))
	}
	return connect.NewResponse(out), nil
}

func (h *PackHandler) UpdatePack(ctx context.Context, req *connect.Request[packv1.UpdatePackRequest]) (*connect.Response[packv1.UpdatePackResponse], error) {
	pack, err := h.packs.Update(ctx, req.Msg.GetId(), req.Msg.Title, req.Msg.DesignBasis)
	if err != nil {
		return nil, toConnectError(err)
	}
	return connect.NewResponse(&packv1.UpdatePackResponse{Pack: toProtoPack(pack)}), nil
}

func (h *PackHandler) ApprovePack(ctx context.Context, req *connect.Request[packv1.ApprovePackRequest]) (*connect.Response[packv1.ApprovePackResponse], error) {
	pack, err := h.packs.Approve(ctx, actor(ctx), req.Msg.GetId())
	if err != nil {
		return nil, toConnectError(err)
	}
	return connect.NewResponse(&packv1.ApprovePackResponse{Pack: toProtoPack(pack)}), nil
}

func (h *PackHandler) CancelPack(ctx context.Context, req *connect.Request[packv1.CancelPackRequest]) (*connect.Response[packv1.CancelPackResponse], error) {
	pack, err := h.packs.Cancel(ctx, actor(ctx), req.Msg.GetId(), req.Msg.GetReason())
	if err != nil {
		return nil, toConnectError(err)
	}
	return connect.NewResponse(&packv1.CancelPackResponse{Pack: toProtoPack(pack)}), nil
}

func (h *PackHandler) UploadDocument(ctx context.Context, req *connect.Request[packv1.UploadDocumentRequest]) (*connect.Response[packv1.UploadDocumentResponse], error) {
	m := req.Msg
	doc, err := h.docs.Upload(ctx, actor(ctx), service.UploadInput{
		PackID: m.GetPackId(), Filename: m.GetFilename(), MimeType: m.GetMimeType(),
		Content: m.GetContent(), Title: m.GetTitle(),
	})
	if err != nil {
		return nil, toConnectError(err)
	}
	return connect.NewResponse(&packv1.UploadDocumentResponse{Document: toProtoDocument(doc)}), nil
}

func (h *PackHandler) GetDocument(ctx context.Context, req *connect.Request[packv1.GetDocumentRequest]) (*connect.Response[packv1.GetDocumentResponse], error) {
	doc, content, err := h.docs.Get(ctx, req.Msg.GetId())
	if err != nil {
		return nil, toConnectError(err)
	}
	return connect.NewResponse(&packv1.GetDocumentResponse{Document: toProtoDocument(doc), ParsedContent: content}), nil
}

// WatchPack: subscribe first, then send the current pack and run, replay
// issue events after the cursor, and follow changes as the hub signals them.
func (h *PackHandler) WatchPack(ctx context.Context, req *connect.Request[packv1.WatchPackRequest], stream *connect.ServerStream[packv1.WatchPackResponse]) error {
	packID := req.Msg.GetPackId()
	cursor := req.Msg.GetAfterSeq()
	if cursor < 0 {
		return connect.NewError(connect.CodeInvalidArgument, errors.New("after_seq cannot be negative"))
	}
	if _, _, _, err := h.packs.Get(ctx, packID); err != nil {
		return toConnectError(err)
	}

	sub := h.hub.Subscribe(packID)
	defer sub.Close()

	sendPack := func() error {
		pack, err := h.st.GetPack(ctx, packID)
		if err != nil {
			return err
		}
		return stream.Send(&packv1.WatchPackResponse{Update: &packv1.WatchPackResponse_PackUpdated{PackUpdated: toProtoPack(pack)}})
	}
	sendRun := func() error {
		run, err := h.packs.LatestRun(ctx, packID)
		if err != nil || run == nil {
			return err
		}
		return stream.Send(&packv1.WatchPackResponse{Update: &packv1.WatchPackResponse_RunUpdated{RunUpdated: toProtoRun(*run)}})
	}
	sendIssues := func() error {
		for {
			events, err := h.st.IssueEventsAfter(ctx, packID, cursor, replayBatch)
			if err != nil || len(events) == 0 {
				return err
			}
			ids := make([]string, 0, len(events))
			for _, e := range events {
				ids = append(ids, e.IssueID)
			}
			current, err := h.st.IssuesByID(ctx, ids)
			if err != nil {
				return err
			}
			for _, e := range events {
				issue, ok := current[e.IssueID]
				if !ok {
					return fmt.Errorf("issue %s of event %d not found", e.IssueID, e.Seq)
				}
				if err := stream.Send(&packv1.WatchPackResponse{Update: &packv1.WatchPackResponse_IssueChanged{
					IssueChanged: &issuev1.IssueChanged{Event: toProtoEvent(e), Issue: toProtoIssue(issue)},
				}}); err != nil {
					return err
				}
				cursor = e.Seq
			}
			if len(events) < replayBatch {
				return nil
			}
		}
	}

	if err := sendPack(); err != nil {
		return streamError(ctx, err)
	}
	if err := sendRun(); err != nil {
		return streamError(ctx, err)
	}
	if err := sendIssues(); err != nil {
		return streamError(ctx, err)
	}

	heartbeat := time.NewTicker(heartbeatInterval)
	defer heartbeat.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-heartbeat.C:
			if err := stream.Send(&packv1.WatchPackResponse{Update: &packv1.WatchPackResponse_Heartbeat{Heartbeat: &packv1.Heartbeat{}}}); err != nil {
				return streamError(ctx, err)
			}
		case <-sub.Ready():
			c := sub.Take()
			// Issues first, so a pack snapshot's counts never run ahead of
			// the issue events the client has seen.
			if c.Issues {
				if err := sendIssues(); err != nil {
					return streamError(ctx, err)
				}
			}
			if c.Run {
				if err := sendRun(); err != nil {
					return streamError(ctx, err)
				}
			}
			if c.Pack {
				if err := sendPack(); err != nil {
					return streamError(ctx, err)
				}
			}
		}
	}
}

// streamError ends a stream: quietly when the client went away, as a
// Connect error otherwise.
func streamError(ctx context.Context, err error) error {
	if ctx.Err() != nil {
		return nil
	}
	return toConnectError(err)
}

// documentOriginal serves GET /api/documents/{id}/original: the uploaded
// file, as an attachment. Same session cookie as the Connect API.
func documentOriginal(auth *service.Auth, docs *service.Documents) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, err := auth.UserForToken(r.Context(), sessionToken(r.Header)); err != nil {
			if errors.Is(err, service.ErrNoSession) {
				http.Error(w, "sign in required", http.StatusUnauthorized)
				return
			}
			_ = internal(err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		doc, body, err := docs.Original(r.Context(), r.PathValue("id"))
		if err != nil {
			var invalidErr *service.InvalidError
			switch {
			case errors.Is(err, service.ErrNotFound), errors.As(err, &invalidErr):
				http.Error(w, "document not found", http.StatusNotFound)
			default:
				_ = internal(err)
				http.Error(w, "internal error", http.StatusInternalServerError)
			}
			return
		}
		w.Header().Set("Content-Type", doc.MimeType)
		w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", strings.ReplaceAll(doc.Filename, `"`, "")))
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Write(body)
	})
}
