// Command devenv manages the local resources of a tools/wt worktree
// environment: one Postgres database and one object-storage bucket per
// environment, carved out of the local Postgres and MinIO that
// docker-compose.yml runs.
//
//	devenv names <slug>    print the environment's settings as dotenv lines
//	devenv create <slug>   create its database (idempotent), then print the same
//	devenv destroy <slug>  drop its database and bucket (missing ones are fine)
//	devenv check           confirm Postgres and object storage answer
//
// The base settings come from the primary checkout's env file (ENV_FILE, or
// the nearest .env). Names are derived from them: database
// <base-db>_wt_<slug> and bucket <base-bucket>-wt-<slug>. The bucket itself is
// created by cmd/seed, like the primary's.
//
// It refuses to touch anything but a local Postgres and object store: drop
// is one typo away from a real database otherwise.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"os"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sektor-ai/material-review-starter/go/internal/config"
	"github.com/sektor-ai/material-review-starter/go/internal/storage"
)

// Must match SLUG_PATTERN in tools/wt/lib/common.sh.
var slugPattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?$`)

func main() {
	if err := run(context.Background(), os.Args[1:]); err != nil {
		slog.Error("devenv failed", "err", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: devenv names|create|destroy <slug> | devenv check")
	}
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if err := requireLocal(cfg); err != nil {
		return err
	}

	cmd, rest := args[0], args[1:]
	if cmd == "check" {
		return check(ctx, cfg)
	}
	if len(rest) != 1 || !slugPattern.MatchString(rest[0]) {
		return fmt.Errorf("%s takes one slug (lowercase letters, digits and dashes)", cmd)
	}
	env, err := namesFor(cfg, rest[0])
	if err != nil {
		return err
	}

	switch cmd {
	case "names":
		env.print()
		return nil
	case "create":
		if err := createDatabase(ctx, cfg.DatabaseURL, env.database); err != nil {
			return err
		}
		env.print()
		return nil
	case "destroy":
		return destroy(ctx, cfg, env)
	default:
		return fmt.Errorf("unknown command %q", cmd)
	}
}

type envNames struct {
	database    string
	databaseURL string
	bucket      string
}

func (e envNames) print() {
	fmt.Printf("DATABASE_NAME=%s\nDATABASE_URL=%s\nS3_BUCKET=%s\n", e.database, e.databaseURL, e.bucket)
}

func namesFor(cfg config.Config, slug string) (envNames, error) {
	u, err := url.Parse(cfg.DatabaseURL)
	if err != nil {
		return envNames{}, fmt.Errorf("parsing DATABASE_URL: %w", err)
	}
	base := strings.TrimPrefix(u.Path, "/")
	if base == "" {
		return envNames{}, errors.New("DATABASE_URL names no database")
	}
	database := base + "_wt_" + strings.ReplaceAll(slug, "-", "_")
	u.Path = "/" + database
	return envNames{
		database:    database,
		databaseURL: u.String(),
		bucket:      cfg.S3.Bucket + "-wt-" + slug,
	}, nil
}

func createDatabase(ctx context.Context, adminURL, name string) error {
	conn, err := pgx.Connect(ctx, adminURL)
	if err != nil {
		return fmt.Errorf("connecting to postgres (is it running? make setup): %w", err)
	}
	defer conn.Close(ctx)

	var exists bool
	if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)`, name).Scan(&exists); err != nil {
		return fmt.Errorf("checking database %s: %w", name, err)
	}
	if exists {
		slog.Info("database already exists", "database", name)
		return nil
	}
	if _, err := conn.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()); err != nil {
		return fmt.Errorf("creating database %s: %w", name, err)
	}
	slog.Info("created database", "database", name)
	return nil
}

// destroy drops the database (disconnecting anything still attached) and the
// bucket. It tries both even if one fails, so a half-gone environment can
// always be finished off by running it again.
func destroy(ctx context.Context, cfg config.Config, env envNames) error {
	var errs []error

	conn, err := pgx.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		errs = append(errs, fmt.Errorf("connecting to postgres: %w", err))
	} else {
		defer conn.Close(ctx)
		if _, err := conn.Exec(ctx, "DROP DATABASE IF EXISTS "+pgx.Identifier{env.database}.Sanitize()+" WITH (FORCE)"); err != nil {
			errs = append(errs, fmt.Errorf("dropping database %s: %w", env.database, err))
		} else {
			slog.Info("dropped database", "database", env.database)
		}
	}

	s3 := cfg.S3
	s3.Bucket = env.bucket
	stg, err := storage.New(s3)
	if err == nil {
		err = stg.DeleteBucket(ctx)
	}
	if err != nil {
		errs = append(errs, err)
	} else {
		slog.Info("deleted bucket", "bucket", env.bucket)
	}
	return errors.Join(errs...)
}

func check(ctx context.Context, cfg config.Config) error {
	conn, err := pgx.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("postgres not reachable (make setup): %w", err)
	}
	conn.Close(ctx)

	stg, err := storage.New(cfg.S3)
	if err != nil {
		return err
	}
	if err := stg.Ping(ctx); err != nil {
		return fmt.Errorf("%w (make setup)", err)
	}
	fmt.Println("postgres and object storage reachable")
	return nil
}

// requireLocal refuses to run against anything but services on this machine.
func requireLocal(cfg config.Config) error {
	u, err := url.Parse(cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("parsing DATABASE_URL: %w", err)
	}
	if !isLocal(u.Hostname()) {
		return fmt.Errorf("DATABASE_URL host %q is not local; devenv only manages the local docker-compose Postgres", u.Hostname())
	}
	host, _, err := net.SplitHostPort(cfg.S3.Endpoint)
	if err != nil {
		host = cfg.S3.Endpoint
	}
	if !isLocal(host) {
		return fmt.Errorf("S3_ENDPOINT host %q is not local; devenv only manages the local MinIO", host)
	}
	return nil
}

func isLocal(host string) bool {
	switch host {
	case "localhost", "127.0.0.1", "::1":
		return true
	}
	return false
}
