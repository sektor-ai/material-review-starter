// Package service holds business logic, independent of transport.
package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"

	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

const SessionTTL = 7 * 24 * time.Hour

var ErrInvalidCredentials = errors.New("invalid email or password")
var ErrNoSession = errors.New("no valid session")

// UserStore is the persistence the auth service needs.
type UserStore interface {
	CreateUser(ctx context.Context, name, email, passwordHash string) (store.User, error)
	UserByEmail(ctx context.Context, email string) (store.User, error)
	CreateSession(ctx context.Context, tokenHash []byte, userID string, expiresAt time.Time) error
	UserBySession(ctx context.Context, tokenHash []byte) (store.User, error)
	DeleteSession(ctx context.Context, tokenHash []byte) error
}

type Auth struct {
	store   UserStore
	now     func() time.Time
	compare func(hash, password []byte) error
}

func NewAuth(s UserStore) *Auth {
	return &Auth{store: s, now: time.Now, compare: bcrypt.CompareHashAndPassword}
}

// dummyHash is compared against when the email has no account, so a failed
// sign-in costs one bcrypt comparison either way and its timing does not
// reveal which emails are registered. Generated once, on first use.
var dummyHash = sync.OnceValue(func() []byte {
	hash, err := bcrypt.GenerateFromPassword([]byte("no account has this password"), bcrypt.DefaultCost)
	if err != nil {
		panic(fmt.Sprintf("generating dummy bcrypt hash: %v", err))
	}
	return hash
})

// normalizeEmail is the one form an email is stored and looked up in. The
// database enforces it too (migration 0003).
func normalizeEmail(email string) string {
	return strings.ToLower(strings.TrimSpace(email))
}

// CreateUser hashes the password and stores a new user.
func (a *Auth) CreateUser(ctx context.Context, name, email, password string) (store.User, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return store.User{}, fmt.Errorf("hashing password: %w", err)
	}
	return a.store.CreateUser(ctx, name, normalizeEmail(email), string(hash))
}

// SignIn checks credentials and starts a session. It returns the session
// token to put in the cookie and its expiry.
func (a *Auth) SignIn(ctx context.Context, email, password string) (store.User, string, time.Time, error) {
	user, err := a.store.UserByEmail(ctx, normalizeEmail(email))
	if errors.Is(err, store.ErrNotFound) {
		_ = a.compare(dummyHash(), []byte(password))
		return store.User{}, "", time.Time{}, ErrInvalidCredentials
	}
	if err != nil {
		return store.User{}, "", time.Time{}, err
	}
	if a.compare([]byte(user.PasswordHash), []byte(password)) != nil {
		return store.User{}, "", time.Time{}, ErrInvalidCredentials
	}

	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return store.User{}, "", time.Time{}, fmt.Errorf("generating session token: %w", err)
	}
	token := base64.RawURLEncoding.EncodeToString(raw)
	expiresAt := a.now().Add(SessionTTL)
	if err := a.store.CreateSession(ctx, hashToken(token), user.ID, expiresAt); err != nil {
		return store.User{}, "", time.Time{}, err
	}
	return user, token, expiresAt, nil
}

// UserForToken returns the user for a session token, or ErrNoSession.
func (a *Auth) UserForToken(ctx context.Context, token string) (store.User, error) {
	if token == "" {
		return store.User{}, ErrNoSession
	}
	user, err := a.store.UserBySession(ctx, hashToken(token))
	if errors.Is(err, store.ErrNotFound) {
		return store.User{}, ErrNoSession
	}
	return user, err
}

func (a *Auth) SignOut(ctx context.Context, token string) error {
	if token == "" {
		return nil
	}
	return a.store.DeleteSession(ctx, hashToken(token))
}

func hashToken(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}
