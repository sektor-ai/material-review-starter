// Command agent-setup creates or updates the Managed Agent and its
// environment, and writes AGENT_ID and ENVIRONMENT_ID to the repo .env.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"

	"github.com/sektor-ai/material-review-starter/go/internal/config"
	"github.com/sektor-ai/material-review-starter/go/internal/llm"
)

func main() {
	if err := run(context.Background()); err != nil {
		slog.Error("agent setup failed", "err", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	// The agent and its environment are shared by every checkout, so their ids
	// belong in the primary checkout's .env. Under ENV_FILE (a tools/wt
	// environment) the write would land in a rendered app.env that the next
	// `wt recreate-config` overwrites.
	if path := os.Getenv("ENV_FILE"); path != "" {
		return fmt.Errorf("ENV_FILE is set (%s): agent-setup writes the shared agent ids to the primary checkout's .env; run `make agent-setup` from the primary, then `wt recreate-config <slug>` to pass them on", path)
	}
	envPath, ok := config.FindEnvFile()
	if !ok {
		return errors.New("no .env found in this repository; copy .env.example to .env first")
	}
	cfg, err := config.LoadAgent()
	if err != nil {
		return err
	}

	spec := llm.ReviewerAgent
	if m := os.Getenv("ANTHROPIC_MODEL"); m != "" {
		spec.Model = m
	}

	client := llm.NewClient()
	envID, created, err := client.EnsureEnvironment(ctx, cfg.EnvironmentID)
	if err != nil {
		return err
	}
	slog.Info("environment ready", "id", envID, "created", created)

	agentID, version, err := client.EnsureAgent(ctx, cfg.AgentID, spec)
	if err != nil {
		return err
	}
	slog.Info("agent ready", "id", agentID, "version", version)

	if err := config.WriteEnvValues(envPath, map[string]string{
		"ENVIRONMENT_ID": envID,
		"AGENT_ID":       agentID,
	}); err != nil {
		return err
	}
	slog.Info("wrote AGENT_ID and ENVIRONMENT_ID", "file", envPath)
	return nil
}
