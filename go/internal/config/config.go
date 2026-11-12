// Package config loads settings from environment variables. Locally they come
// from the repo-root .env file; on Cloud Run they are injected by the service.
package config

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type Config struct {
	DatabaseURL  string
	Port         int
	CookieSecure bool

	S3 S3

	AgentID       string
	EnvironmentID string
}

type S3 struct {
	Endpoint        string // host[:port], no scheme
	UseSSL          bool
	Region          string
	AccessKeyID     string
	SecretAccessKey string
	Bucket          string
}

// Load reads an env file into the process environment, then builds a Config.
//
// An explicit ENV_FILE wins over variables already exported: a worktree
// environment (tools/wt) points ENV_FILE at its own settings, and a
// DATABASE_URL left exported in the shell must not quietly send it to the
// primary's database. A .env found by walking up is only a default, so it
// never overrides what is already set.
func Load() (Config, error) {
	if err := loadEnv(); err != nil {
		return Config{}, err
	}

	var missing []string
	required := func(name string) string {
		v := os.Getenv(name)
		if v == "" {
			missing = append(missing, name)
		}
		return v
	}

	endpoint, useSSL := splitEndpoint(required("S3_ENDPOINT"))
	cfg := Config{
		DatabaseURL:  required("DATABASE_URL"),
		Port:         intOr("PORT", 8787),
		CookieSecure: os.Getenv("COOKIE_SECURE") == "true",
		S3: S3{
			Endpoint:        endpoint,
			UseSSL:          useSSL,
			Region:          stringOr("S3_REGION", "us-east-1"),
			AccessKeyID:     required("S3_ACCESS_KEY_ID"),
			SecretAccessKey: required("S3_SECRET_ACCESS_KEY"),
			Bucket:          required("S3_BUCKET"),
		},
		AgentID:       os.Getenv("AGENT_ID"),
		EnvironmentID: os.Getenv("ENVIRONMENT_ID"),
	}
	if len(missing) > 0 {
		return Config{}, fmt.Errorf("missing %s (see .env.example)", strings.Join(missing, ", "))
	}
	return cfg, nil
}

// Agent is the configuration of the Managed Agent the reviewer runs on. It is
// all cmd/agent-setup needs, so that command does not require a database or
// object storage to be configured.
type Agent struct {
	AgentID       string
	EnvironmentID string
}

// LoadAgent reads the env file (as Load does) and returns only the agent ids.
// Both may be empty: agent-setup creates what is missing.
func LoadAgent() (Agent, error) {
	if err := loadEnv(); err != nil {
		return Agent{}, err
	}
	return Agent{AgentID: os.Getenv("AGENT_ID"), EnvironmentID: os.Getenv("ENVIRONMENT_ID")}, nil
}

// loadEnv loads ENV_FILE if set (overriding exported variables), else the
// nearest .env (never overriding).
func loadEnv() error {
	if path := os.Getenv("ENV_FILE"); path != "" {
		return loadEnvFile(path, true)
	}
	if path, ok := FindEnvFile(); ok {
		return loadEnvFile(path, false)
	}
	return nil
}

// FindEnvFile returns ENV_FILE when it is set, so a worktree environment
// (tools/wt) can point every command at its own rendered settings. Otherwise
// it walks up from the working directory looking for a .env file, stopping at
// the repository root (the first directory holding a .git directory or, in a
// worktree, a .git file): a .env above the repository, such as ~/.env, belongs
// to something else.
func FindEnvFile() (string, bool) {
	if path := os.Getenv("ENV_FILE"); path != "" {
		return path, true
	}
	dir, err := os.Getwd()
	if err != nil {
		return "", false
	}
	for {
		path := filepath.Join(dir, ".env")
		if _, err := os.Stat(path); err == nil {
			return path, true
		}
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return "", false
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
}

// loadEnvFile sets each NAME=value from the file. With override false, names
// already set in the environment keep their value.
func loadEnvFile(path string, override bool) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("opening %s: %w", path, err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		name = envName(name)
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		if _, set := os.LookupEnv(name); override || !set {
			os.Setenv(name, value)
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("reading %s: %w", path, err)
	}
	return nil
}

// WriteEnvValues sets name=value lines in the .env file at path, replacing
// existing lines for those names and appending the rest.
func WriteEnvValues(path string, values map[string]string) error {
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("reading %s: %w", path, err)
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) == 1 && lines[0] == "" {
		lines = nil
	}
	for name, value := range values {
		replaced := false
		for i, line := range lines {
			lineName, _, ok := strings.Cut(strings.TrimSpace(line), "=")
			if ok && envName(lineName) == name {
				lines[i] = name + "=" + value
				replaced = true
			}
		}
		if !replaced {
			lines = append(lines, name+"="+value)
		}
	}
	return os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600)
}

// envName normalises the left-hand side of a dotenv line: surrounding spaces
// and a shell `export ` prefix are not part of the name.
func envName(raw string) string {
	name := strings.TrimSpace(raw)
	if rest, ok := strings.CutPrefix(name, "export"); ok && rest != strings.TrimLeft(rest, " \t") {
		name = strings.TrimSpace(rest)
	}
	return name
}

func splitEndpoint(raw string) (host string, useSSL bool) {
	switch {
	case strings.HasPrefix(raw, "https://"):
		return strings.TrimPrefix(raw, "https://"), true
	case strings.HasPrefix(raw, "http://"):
		return strings.TrimPrefix(raw, "http://"), false
	default:
		return raw, true
	}
}

func stringOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func intOr(name string, fallback int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil {
		return v
	}
	return fallback
}
