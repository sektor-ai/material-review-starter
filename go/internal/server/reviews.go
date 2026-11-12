package server

import (
	"context"

	"connectrpc.com/connect"

	reviewv1 "github.com/sektor-ai/material-review-starter/go/gen/review/v1"
	"github.com/sektor-ai/material-review-starter/go/gen/review/v1/reviewv1connect"
	"github.com/sektor-ai/material-review-starter/go/internal/service"
)

type ReviewHandler struct {
	reviews *service.Reviews
}

var _ reviewv1connect.ReviewServiceHandler = (*ReviewHandler)(nil)

func (h *ReviewHandler) StartReview(ctx context.Context, req *connect.Request[reviewv1.StartReviewRequest]) (*connect.Response[reviewv1.StartReviewResponse], error) {
	run, err := h.reviews.Start(ctx, actor(ctx), req.Msg.GetPackId(), req.Msg.GetInstructions())
	if err != nil {
		return nil, toConnectError(err)
	}
	return connect.NewResponse(&reviewv1.StartReviewResponse{Run: toProtoRun(run)}), nil
}

func (h *ReviewHandler) GetReviewRun(ctx context.Context, req *connect.Request[reviewv1.GetReviewRunRequest]) (*connect.Response[reviewv1.GetReviewRunResponse], error) {
	run, err := h.reviews.Get(ctx, req.Msg.GetId())
	if err != nil {
		return nil, toConnectError(err)
	}
	return connect.NewResponse(&reviewv1.GetReviewRunResponse{Run: toProtoRun(run)}), nil
}

func (h *ReviewHandler) ListReviewRuns(ctx context.Context, req *connect.Request[reviewv1.ListReviewRunsRequest]) (*connect.Response[reviewv1.ListReviewRunsResponse], error) {
	runs, err := h.reviews.List(ctx, req.Msg.GetPackId())
	if err != nil {
		return nil, toConnectError(err)
	}
	out := &reviewv1.ListReviewRunsResponse{Runs: make([]*reviewv1.ReviewRun, 0, len(runs))}
	for _, r := range runs {
		out.Runs = append(out.Runs, toProtoRun(r))
	}
	return connect.NewResponse(out), nil
}

func (h *ReviewHandler) CancelReviewRun(ctx context.Context, req *connect.Request[reviewv1.CancelReviewRunRequest]) (*connect.Response[reviewv1.CancelReviewRunResponse], error) {
	run, err := h.reviews.Cancel(ctx, req.Msg.GetId())
	if err != nil {
		return nil, toConnectError(err)
	}
	return connect.NewResponse(&reviewv1.CancelReviewRunResponse{Run: toProtoRun(run)}), nil
}
