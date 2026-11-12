// Package server is the transport layer: Connect handlers that decode
// requests, call internal/service, and encode responses.
package server

import (
	"context"
	"errors"
	"net/http"
	"time"

	"connectrpc.com/connect"

	authv1 "github.com/sektor-ai/material-review-starter/go/gen/auth/v1"
	"github.com/sektor-ai/material-review-starter/go/gen/auth/v1/authv1connect"
	"github.com/sektor-ai/material-review-starter/go/internal/service"
)

const sessionCookie = "session"

type AuthHandler struct {
	auth         *service.Auth
	cookieSecure bool
}

var _ authv1connect.AuthServiceHandler = (*AuthHandler)(nil)

func NewAuthHandler(auth *service.Auth, cookieSecure bool) *AuthHandler {
	return &AuthHandler{auth: auth, cookieSecure: cookieSecure}
}

func (h *AuthHandler) SignIn(ctx context.Context, req *connect.Request[authv1.SignInRequest]) (*connect.Response[authv1.SignInResponse], error) {
	user, token, expiresAt, err := h.auth.SignIn(ctx, req.Msg.GetEmail(), req.Msg.GetPassword())
	if errors.Is(err, service.ErrInvalidCredentials) {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	if err != nil {
		return nil, internal(err)
	}
	resp := connect.NewResponse(&authv1.SignInResponse{User: toProtoUser(user)})
	resp.Header().Add("Set-Cookie", h.cookie(token, expiresAt).String())
	return resp, nil
}

func (h *AuthHandler) SignOut(ctx context.Context, req *connect.Request[authv1.SignOutRequest]) (*connect.Response[authv1.SignOutResponse], error) {
	if err := h.auth.SignOut(ctx, sessionToken(req.Header())); err != nil {
		return nil, internal(err)
	}
	resp := connect.NewResponse(&authv1.SignOutResponse{})
	resp.Header().Add("Set-Cookie", h.cookie("", time.Unix(0, 0)).String())
	return resp, nil
}

func (h *AuthHandler) GetMe(ctx context.Context, req *connect.Request[authv1.GetMeRequest]) (*connect.Response[authv1.GetMeResponse], error) {
	user, err := h.auth.UserForToken(ctx, sessionToken(req.Header()))
	if errors.Is(err, service.ErrNoSession) {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	if err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&authv1.GetMeResponse{User: toProtoUser(user)}), nil
}

func (h *AuthHandler) cookie(value string, expires time.Time) *http.Cookie {
	return &http.Cookie{
		Name:     sessionCookie,
		Value:    value,
		Path:     "/",
		Expires:  expires,
		HttpOnly: true,
		Secure:   h.cookieSecure,
		SameSite: http.SameSiteLaxMode,
	}
}

func sessionToken(header http.Header) string {
	c, err := (&http.Request{Header: header}).Cookie(sessionCookie)
	if err != nil {
		return ""
	}
	return c.Value
}
