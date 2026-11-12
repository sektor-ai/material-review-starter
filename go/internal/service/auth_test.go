package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

type fakeStore struct {
	users    map[string]store.User // by email
	sessions map[string]struct {
		userID  string
		expires time.Time
	}
	now func() time.Time
}

func newFakeStore(now func() time.Time) *fakeStore {
	return &fakeStore{users: map[string]store.User{}, sessions: map[string]struct {
		userID  string
		expires time.Time
	}{}, now: now}
}

func (f *fakeStore) CreateUser(_ context.Context, name, email, hash string) (store.User, error) {
	u := store.User{ID: "u-" + email, Name: name, Email: email, PasswordHash: hash}
	f.users[email] = u
	return u, nil
}

func (f *fakeStore) UserByEmail(_ context.Context, email string) (store.User, error) {
	u, ok := f.users[email]
	if !ok {
		return store.User{}, store.ErrNotFound
	}
	return u, nil
}

func (f *fakeStore) CreateSession(_ context.Context, hash []byte, userID string, expires time.Time) error {
	f.sessions[string(hash)] = struct {
		userID  string
		expires time.Time
	}{userID, expires}
	return nil
}

func (f *fakeStore) UserBySession(_ context.Context, hash []byte) (store.User, error) {
	s, ok := f.sessions[string(hash)]
	if !ok || !s.expires.After(f.now()) {
		return store.User{}, store.ErrNotFound
	}
	for _, u := range f.users {
		if u.ID == s.userID {
			return u, nil
		}
	}
	return store.User{}, store.ErrNotFound
}

func (f *fakeStore) DeleteSession(_ context.Context, hash []byte) error {
	delete(f.sessions, string(hash))
	return nil
}

func TestAuth(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	fs := newFakeStore(clock)
	a := NewAuth(fs)
	a.now = clock

	if _, err := a.CreateUser(ctx, "Alice", "alice@example.com", "password123"); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name, email, password string
		wantErr               error
	}{
		{"valid", "alice@example.com", "password123", nil},
		{"wrong password", "alice@example.com", "nope", ErrInvalidCredentials},
		{"unknown email", "eve@example.com", "password123", ErrInvalidCredentials},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, _, _, err := a.SignIn(ctx, tt.email, tt.password)
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("SignIn error = %v, want %v", err, tt.wantErr)
			}
		})
	}

	t.Run("session lifecycle", func(t *testing.T) {
		_, token, _, err := a.SignIn(ctx, "alice@example.com", "password123")
		if err != nil {
			t.Fatal(err)
		}
		u, err := a.UserForToken(ctx, token)
		if err != nil || u.Email != "alice@example.com" {
			t.Fatalf("UserForToken = %v, %v", u, err)
		}
		if _, err := a.UserForToken(ctx, "bogus"); !errors.Is(err, ErrNoSession) {
			t.Fatalf("bogus token error = %v, want ErrNoSession", err)
		}

		now = now.Add(SessionTTL + time.Minute)
		if _, err := a.UserForToken(ctx, token); !errors.Is(err, ErrNoSession) {
			t.Fatalf("expired token error = %v, want ErrNoSession", err)
		}
		now = now.Add(-SessionTTL - time.Minute)

		if err := a.SignOut(ctx, token); err != nil {
			t.Fatal(err)
		}
		if _, err := a.UserForToken(ctx, token); !errors.Is(err, ErrNoSession) {
			t.Fatalf("signed-out token error = %v, want ErrNoSession", err)
		}
	})
}

func TestEmailIsCaseInsensitive(t *testing.T) {
	ctx := context.Background()
	fs := newFakeStore(time.Now)
	a := NewAuth(fs)

	u, err := a.CreateUser(ctx, "Alice", "  Alice@Example.COM ", "password123")
	if err != nil {
		t.Fatal(err)
	}
	if u.Email != "alice@example.com" {
		t.Fatalf("stored email = %q, want it normalised to lower case", u.Email)
	}
	for _, typed := range []string{"alice@example.com", "ALICE@EXAMPLE.COM", " Alice@Example.com "} {
		if _, _, _, err := a.SignIn(ctx, typed, "password123"); err != nil {
			t.Errorf("SignIn(%q) = %v, want success", typed, err)
		}
	}
}

// A sign-in for an unknown email must cost the same bcrypt comparison as a
// wrong password, so response time does not reveal which emails exist.
func TestSignInComparesEvenForUnknownEmail(t *testing.T) {
	ctx := context.Background()
	a := NewAuth(newFakeStore(time.Now))
	if _, err := a.CreateUser(ctx, "Alice", "alice@example.com", "password123"); err != nil {
		t.Fatal(err)
	}
	compares := 0
	orig := a.compare
	a.compare = func(hash, password []byte) error {
		compares++
		return orig(hash, password)
	}

	for _, tc := range []struct{ email, password string }{
		{"nobody@example.com", "password123"},
		{"alice@example.com", "wrong"},
	} {
		compares = 0
		if _, _, _, err := a.SignIn(ctx, tc.email, tc.password); !errors.Is(err, ErrInvalidCredentials) {
			t.Fatalf("SignIn(%q) error = %v, want ErrInvalidCredentials", tc.email, err)
		}
		if compares != 1 {
			t.Errorf("SignIn(%q) made %d bcrypt comparisons, want 1", tc.email, compares)
		}
	}
}
