package service

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

// Changes says what changed in a pack since a subscriber last looked.
type Changes struct {
	Issues bool
	Run    bool
	Pack   bool
}

func (c Changes) any() bool { return c.Issues || c.Run || c.Pack }

var allChanged = Changes{Issues: true, Run: true, Pack: true}

// Hub fans database notifications out to WatchPack streams. Signals are
// coalesced, never queued: a subscriber learns *what kind* of thing changed
// and re-reads it from the database, so a slow stream cannot fall behind or
// lose a change, it just catches up in one read.
type Hub struct {
	st *store.Store

	mu   sync.Mutex
	subs map[string]map[*Subscription]struct{} // by pack id
}

func NewHub(st *store.Store) *Hub {
	return &Hub{st: st, subs: map[string]map[*Subscription]struct{}{}}
}

type Subscription struct {
	hub    *Hub
	packID string

	mu      sync.Mutex
	pending Changes
	ready   chan struct{}
}

// Subscribe starts collecting changes for a pack. Subscribe before reading
// the state you send, so nothing committed in between is missed.
func (h *Hub) Subscribe(packID string) *Subscription {
	s := &Subscription{hub: h, packID: packID, ready: make(chan struct{}, 1)}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subs[packID] == nil {
		h.subs[packID] = map[*Subscription]struct{}{}
	}
	h.subs[packID][s] = struct{}{}
	return s
}

func (s *Subscription) Close() {
	s.hub.mu.Lock()
	defer s.hub.mu.Unlock()
	delete(s.hub.subs[s.packID], s)
	if len(s.hub.subs[s.packID]) == 0 {
		delete(s.hub.subs, s.packID)
	}
}

// Ready receives when there are changes to Take.
func (s *Subscription) Ready() <-chan struct{} { return s.ready }

// Take returns and clears the pending changes.
func (s *Subscription) Take() Changes {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.pending
	s.pending = Changes{}
	return c
}

func (s *Subscription) mark(c Changes) {
	s.mu.Lock()
	s.pending.Issues = s.pending.Issues || c.Issues
	s.pending.Run = s.pending.Run || c.Run
	s.pending.Pack = s.pending.Pack || c.Pack
	s.mu.Unlock()
	select {
	case s.ready <- struct{}{}:
	default: // already signalled
	}
}

func (h *Hub) dispatch(packID string, c Changes) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for s := range h.subs[packID] {
		s.mark(c)
	}
}

func (h *Hub) dispatchAll(c Changes) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, subs := range h.subs {
		for s := range subs {
			s.mark(c)
		}
	}
}

// Run listens for database notifications until ctx ends, reconnecting with
// backoff. After every (re)connect all subscribers resync, since anything
// committed while disconnected was not announced.
func (h *Hub) Run(ctx context.Context) {
	backoff := time.Second
	for {
		err := h.st.Listen(ctx,
			func() {
				backoff = time.Second
				h.dispatchAll(allChanged)
			},
			func(n store.Notification) {
				var c Changes
				switch n.Kind {
				case "issue_event":
					// The pack's open issue count changes with its issues.
					c = Changes{Issues: true, Pack: true}
				case "run":
					c = Changes{Run: true}
				default:
					c = Changes{Pack: true}
				}
				h.dispatch(n.PackID, c)
			})
		if ctx.Err() != nil {
			return
		}
		slog.Error("pack activity listener stopped; reconnecting", "err", err, "in", backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, 30*time.Second)
	}
}
