package main

import (
	"context"
	"strings"
	"testing"
)

// Under ENV_FILE (a tools/wt environment) agent-setup must refuse before
// touching anything: the ids belong in the primary's .env, and a rendered
// app.env would be overwritten by the next `wt recreate-config`.
func TestRefusesUnderEnvFile(t *testing.T) {
	t.Setenv("ENV_FILE", "/tmp/some/app.env")
	err := run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "primary checkout's .env") {
		t.Fatalf("run() error = %v, want a refusal pointing at the primary's .env", err)
	}
}
