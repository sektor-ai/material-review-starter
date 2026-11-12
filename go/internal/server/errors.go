package server

import (
	"context"
	"errors"

	"connectrpc.com/connect"

	"github.com/sektor-ai/material-review-starter/go/internal/service"
)

// toConnectError maps service errors to Connect codes. Anything unexpected
// is logged and returned as a generic Internal error.
func toConnectError(err error) error {
	var (
		invalidErr      *service.InvalidError
		preconditionErr *service.PreconditionError
		conflictErr     *service.ConflictError
	)
	switch {
	case err == nil:
		return nil
	case errors.As(err, &invalidErr):
		return connect.NewError(connect.CodeInvalidArgument, invalidErr)
	case errors.As(err, &preconditionErr):
		return connect.NewError(connect.CodeFailedPrecondition, preconditionErr)
	case errors.As(err, &conflictErr):
		cerr := connect.NewError(connect.CodeAborted, conflictErr)
		// The current issue rides along so the client can show it.
		if detail, derr := connect.NewErrorDetail(toProtoIssue(conflictErr.Current)); derr == nil {
			cerr.AddDetail(detail)
		}
		return cerr
	case errors.Is(err, service.ErrNotFound):
		return connect.NewError(connect.CodeNotFound, err)
	case errors.Is(err, service.ErrAlreadyExists):
		return connect.NewError(connect.CodeAlreadyExists, err)
	case errors.Is(err, context.Canceled):
		return connect.NewError(connect.CodeCanceled, err)
	case errors.Is(err, context.DeadlineExceeded):
		return connect.NewError(connect.CodeDeadlineExceeded, err)
	}
	return internal(err)
}
