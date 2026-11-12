package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFile(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "app.env")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestEnvName(t *testing.T) {
	tests := map[string]string{
		"DATABASE_URL":         "DATABASE_URL",
		"  DATABASE_URL ":      "DATABASE_URL",
		"export DATABASE_URL":  "DATABASE_URL",
		"export\tDATABASE_URL": "DATABASE_URL",
		"exportED":             "exportED",
		"EXPORTER_URL":         "EXPORTER_URL",
	}
	for in, want := range tests {
		if got := envName(in); got != want {
			t.Errorf("envName(%q) = %q, want %q", in, got, want)
		}
	}
}

// An explicit ENV_FILE must beat an exported variable: otherwise a worktree
// environment launched from a shell with DATABASE_URL exported would run
// against the primary's database.
func TestLoadExplicitEnvFileOverridesEnvironment(t *testing.T) {
	path := writeFile(t, strings.Join([]string{
		`export DATABASE_URL="postgres://u:p@localhost/env_db"`,
		`S3_ENDPOINT = http://localhost:9000`,
		`S3_ACCESS_KEY_ID=a`,
		`S3_SECRET_ACCESS_KEY=b`,
		`S3_BUCKET='env-bucket'`,
	}, "\n"))
	t.Setenv("ENV_FILE", path)
	t.Setenv("DATABASE_URL", "postgres://u:p@localhost/primary_db")
	t.Setenv("S3_BUCKET", "primary-bucket")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DatabaseURL != "postgres://u:p@localhost/env_db" {
		t.Errorf("DatabaseURL = %q, want the ENV_FILE value", cfg.DatabaseURL)
	}
	if cfg.S3.Bucket != "env-bucket" {
		t.Errorf("S3.Bucket = %q, want the ENV_FILE value", cfg.S3.Bucket)
	}
	if cfg.S3.Endpoint != "localhost:9000" {
		t.Errorf("S3.Endpoint = %q (spaces around '=' not handled)", cfg.S3.Endpoint)
	}
}

// A discovered .env is only a default: exported variables keep their value.
func TestLoadDiscoveredEnvFileDoesNotOverride(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("DATABASE_URL=postgres://from/file\nS3_ENDPOINT=x\nS3_ACCESS_KEY_ID=a\nS3_SECRET_ACCESS_KEY=b\nS3_BUCKET=c\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	t.Setenv("ENV_FILE", "")
	t.Setenv("DATABASE_URL", "postgres://from/shell")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DatabaseURL != "postgres://from/shell" {
		t.Errorf("DatabaseURL = %q, want the exported value", cfg.DatabaseURL)
	}
}

func TestWriteEnvValuesRewritesExportAndSpacedLines(t *testing.T) {
	path := writeFile(t, "export AGENT_ID=old\nENVIRONMENT_ID = old\nOTHER=keep\n")
	if err := WriteEnvValues(path, map[string]string{"AGENT_ID": "a1", "ENVIRONMENT_ID": "e1", "NEW": "n"}); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(path)
	want := "AGENT_ID=a1\nENVIRONMENT_ID=e1\nOTHER=keep\nNEW=n\n"
	if string(got) != want {
		t.Errorf("file = %q, want %q", got, want)
	}
}
