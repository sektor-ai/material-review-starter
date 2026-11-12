package store

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
)

// Notification is a pack_activity payload, sent by the database triggers on
// commit (see migration 0002).
type Notification struct {
	PackID string `json:"pack_id"`
	// "issue_event", "run" or "pack".
	Kind string `json:"kind"`
	// Set for "issue_event".
	Seq int64 `json:"seq"`
}

// Listen holds a dedicated connection LISTENing on pack_activity and calls
// handle for each notification until ctx ends or the connection fails.
// onListening runs once the LISTEN is in place; anything committed before
// that may have been missed, so callers resync there.
//
// On Neon, LISTEN needs the direct (unpooled) connection string.
func (s *Store) Listen(ctx context.Context, onListening func(), handle func(Notification)) error {
	pooled, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquiring listen connection: %w", err)
	}
	// Take the connection out of the pool so a LISTENing session is never
	// handed to another caller.
	conn := pooled.Hijack()
	defer conn.Close(context.Background())

	if _, err := conn.Exec(ctx, "LISTEN pack_activity"); err != nil {
		return fmt.Errorf("listening: %w", err)
	}
	onListening()
	for {
		n, err := conn.WaitForNotification(ctx)
		if err != nil {
			return fmt.Errorf("waiting for notification: %w", err)
		}
		var payload Notification
		if err := json.Unmarshal([]byte(n.Payload), &payload); err != nil {
			slog.WarnContext(ctx, "ignoring malformed pack_activity payload", "err", err)
			continue
		}
		handle(payload)
	}
}
