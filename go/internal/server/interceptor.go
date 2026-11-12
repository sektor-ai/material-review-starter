package server

import (
	"context"
	"errors"
	"net/http"

	"connectrpc.com/connect"

	"github.com/sektor-ai/material-review-starter/go/internal/service"
	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

type actorKey struct{}

// actor returns the signed-in user. Handlers behind authInterceptor always
// have one.
func actor(ctx context.Context) store.User {
	u, _ := ctx.Value(actorKey{}).(store.User)
	return u
}

// authInterceptor rejects calls without a valid session cookie and puts
// the session's user in the context.
type authInterceptor struct {
	auth *service.Auth
}

func (a *authInterceptor) resolve(ctx context.Context, header http.Header) (context.Context, error) {
	user, err := a.auth.UserForToken(ctx, sessionToken(header))
	if errors.Is(err, service.ErrNoSession) {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	if err != nil {
		return nil, internal(err)
	}
	return context.WithValue(ctx, actorKey{}, user), nil
}

func (a *authInterceptor) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
		ctx, err := a.resolve(ctx, req.Header())
		if err != nil {
			return nil, err
		}
		return next(ctx, req)
	}
}

func (a *authInterceptor) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return next
}

func (a *authInterceptor) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return func(ctx context.Context, conn connect.StreamingHandlerConn) error {
		ctx, err := a.resolve(ctx, conn.RequestHeader())
		if err != nil {
			return err
		}
		return next(ctx, conn)
	}
}
