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

// The search for .env stops at the repository root: a .env above it (say
// ~/.env) is someone else's settings.
func TestFindEnvFileStopsAtRepoRoot(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".env"), []byte("X=outside\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	repo := filepath.Join(root, "repo")
	for _, tc := range []struct {
		name    string
		gitFile bool // a worktree has a .git file rather than a directory
	}{{"checkout", false}, {"worktree", true}} {
		t.Run(tc.name, func(t *testing.T) {
			if err := os.RemoveAll(repo); err != nil {
				t.Fatal(err)
			}
			sub := filepath.Join(repo, "go", "cmd")
			if err := os.MkdirAll(sub, 0o755); err != nil {
				t.Fatal(err)
			}
			if tc.gitFile {
				err := os.WriteFile(filepath.Join(repo, ".git"), []byte("gitdir: elsewhere\n"), 0o600)
				if err != nil {
					t.Fatal(err)
				}
			} else if err := os.Mkdir(filepath.Join(repo, ".git"), 0o755); err != nil {
				t.Fatal(err)
			}
			t.Chdir(sub)
			t.Setenv("ENV_FILE", "")

			if path, ok := FindEnvFile(); ok {
				t.Fatalf("FindEnvFile found %s above the repository root", path)
			}

			inside := filepath.Join(repo, ".env")
			if err := os.WriteFile(inside, []byte("X=inside\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			path, ok := FindEnvFile()
			if !ok || filepath.Base(filepath.Dir(path)) != "repo" {
				t.Fatalf("FindEnvFile = %q, %v; want the repository's own .env", path, ok)
			}
		})
	}
}

// agent-setup only talks to Anthropic, so loading its config must not demand
// DATABASE_URL or S3 settings.
func TestLoadAgentNeedsOnlyAgentSettings(t *testing.T) {
	path := writeFile(t, "AGENT_ID=agent_1\nENVIRONMENT_ID=env_1\n")
	t.Setenv("ENV_FILE", path)
	for _, name := range []string{"DATABASE_URL", "S3_ENDPOINT", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY", "S3_BUCKET", "AGENT_ID", "ENVIRONMENT_ID"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
	got, err := LoadAgent()
	if err != nil {
		t.Fatalf("LoadAgent with no database or storage settings: %v", err)
	}
	if got != (Agent{AgentID: "agent_1", EnvironmentID: "env_1"}) {
		t.Fatalf("LoadAgent = %+v", got)
	}
}
