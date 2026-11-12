// Package store is the Postgres persistence layer.
package store

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

//go:embed migrations/*.sql
var migrations embed.FS

var ErrNotFound = errors.New("not found")

type Store struct {
	pool *pgxpool.Pool
	db   *sql.DB // database/sql view of pool, for goose
	// migrations knows the embedded migrations and reads the applied version.
	migrations *goose.Provider
}

func Open(ctx context.Context, databaseURL string) (*Store, error) {
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return nil, fmt.Errorf("connecting to postgres: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("pinging postgres: %w", err)
	}
	db := stdlib.OpenDBFromPool(pool)
	provider, err := goose.NewProvider(goose.DialectPostgres, db, mustSub(migrations, "migrations"))
	if err != nil {
		db.Close()
		pool.Close()
		return nil, fmt.Errorf("creating migration provider: %w", err)
	}
	return &Store{pool: pool, db: db, migrations: provider}, nil
}

func (s *Store) Close() {
	s.db.Close()
	s.pool.Close()
}

// Migrate applies all pending migrations from migrations/.
func (s *Store) Migrate(ctx context.Context) error {
	if _, err := s.migrations.Up(ctx); err != nil {
		return fmt.Errorf("applying migrations: %w", err)
	}
	return nil
}

// ErrSchemaBehind means the database has not had every migration this binary
// ships with. The API's /healthz reports it, so a revision deployed ahead of
// its migrations never becomes ready (cmd/migrate, or the Cloud Run migrate
// job, has to run first).
var ErrSchemaBehind = errors.New("database schema is behind this build")

// Ready reports whether the database answers and has every migration applied.
func (s *Store) Ready(ctx context.Context) error {
	if err := s.pool.Ping(ctx); err != nil {
		return fmt.Errorf("pinging postgres: %w", err)
	}
	current, target, err := s.migrations.GetVersions(ctx)
	if err != nil {
		return fmt.Errorf("reading schema version: %w", err)
	}
	if current < target {
		return fmt.Errorf("%w: database at version %d, build expects %d; run migrations", ErrSchemaBehind, current, target)
	}
	return nil
}

type UserKind string

const (
	UserKindHuman UserKind = "human"
	UserKindAgent UserKind = "agent"
)

// User is a row of auth.users. The JSON tags let queries return users as
// jsonb objects (see userJSON).
type User struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	Email        string   `json:"email"` // empty for the agent
	Kind         UserKind `json:"kind"`
	PasswordHash string   `json:"-"`
}

func (s *Store) CreateUser(ctx context.Context, name, email, passwordHash string) (User, error) {
	u := User{Name: name, Email: email, Kind: UserKindHuman, PasswordHash: passwordHash}
	err := s.pool.QueryRow(ctx,
		`INSERT INTO auth.users (name, email, password_hash) VALUES ($1, $2, $3) RETURNING id`,
		name, email, passwordHash,
	).Scan(&u.ID)
	if err != nil {
		return User{}, fmt.Errorf("inserting user %s: %w", email, err)
	}
	return u, nil
}

func (s *Store) UserByEmail(ctx context.Context, email string) (User, error) {
	var u User
	err := s.pool.QueryRow(ctx,
		`SELECT id, name, email, password_hash, kind FROM auth.users
		  WHERE lower(email) = lower($1) AND kind = 'human'`, email,
	).Scan(&u.ID, &u.Name, &u.Email, &u.PasswordHash, &u.Kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, ErrNotFound
	}
	if err != nil {
		return User{}, fmt.Errorf("querying user by email: %w", err)
	}
	return u, nil
}

func (s *Store) CreateSession(ctx context.Context, tokenHash []byte, userID string, expiresAt time.Time) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO auth.sessions (token_hash, user_id, expires_at) VALUES ($1, $2, $3)`,
		tokenHash, userID, expiresAt,
	)
	if err != nil {
		return fmt.Errorf("inserting session: %w", err)
	}
	return nil
}

// UserBySession returns the user owning an unexpired session.
func (s *Store) UserBySession(ctx context.Context, tokenHash []byte) (User, error) {
	var u User
	err := s.pool.QueryRow(ctx,
		`SELECT u.id, u.name, u.email, u.password_hash, u.kind
		   FROM auth.sessions s JOIN auth.users u ON u.id = s.user_id
		  WHERE s.token_hash = $1 AND s.expires_at > now() AND u.kind = 'human'`, tokenHash,
	).Scan(&u.ID, &u.Name, &u.Email, &u.PasswordHash, &u.Kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, ErrNotFound
	}
	if err != nil {
		return User{}, fmt.Errorf("querying session: %w", err)
	}
	return u, nil
}

func (s *Store) DeleteSession(ctx context.Context, tokenHash []byte) error {
	if _, err := s.pool.Exec(ctx, `DELETE FROM auth.sessions WHERE token_hash = $1`, tokenHash); err != nil {
		return fmt.Errorf("deleting session: %w", err)
	}
	return nil
}
