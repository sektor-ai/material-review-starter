package service

import (
	"errors"
	"reflect"
	"testing"

	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

func ptr[T any](v T) *T { return &v }

func baseIssue() store.Issue {
	return store.Issue{
		ID: "i1", Version: 3, Status: store.IssueOpen, Severity: store.SeverityMajor,
		Title: "w/c ratio 0.55 > 0.50", Description: "too high",
		Spec:     store.SpecRef{Section: "05", Part: "06", Clause: "Table 6.4"},
		Evidence: "0.55",
	}
}

func TestApplyUpdate(t *testing.T) {
	tests := []struct {
		name        string
		in          UpdateIssueInput
		wantFields  []string
		wantVersion int32
		wantInvalid bool
	}{
		{name: "nothing set", in: UpdateIssueInput{}, wantVersion: 3},
		{name: "same values are not changes", in: UpdateIssueInput{
			Status: ptr(store.IssueOpen), Title: ptr("  w/c ratio 0.55 > 0.50 "),
			Spec: &store.SpecRef{Section: "05", Part: "06", Clause: "Table 6.4"},
		}, wantVersion: 3},
		{name: "close", in: UpdateIssueInput{Status: ptr(store.IssueClosed)}, wantFields: []string{"status"}, wantVersion: 4},
		{name: "several fields in fixed order", in: UpdateIssueInput{
			Evidence: ptr("0.55 w/c"), Severity: ptr(store.SeverityCritical), Status: ptr(store.IssueClosed),
		}, wantFields: []string{"status", "severity", "evidence"}, wantVersion: 4},
		{name: "spec page counts", in: UpdateIssueInput{
			Spec: &store.SpecRef{Section: "05", Part: "06", Clause: "Table 6.4", PDFPage: ptr(int32(660))},
		}, wantFields: []string{"spec_ref"}, wantVersion: 4},
		{name: "empty title rejected", in: UpdateIssueInput{Title: ptr("  ")}, wantInvalid: true},
		{name: "clause cannot be cleared", in: UpdateIssueInput{Spec: &store.SpecRef{Section: "05", Part: "06"}}, wantInvalid: true},
		{name: "unspecified enum rejected", in: UpdateIssueInput{Severity: ptr(store.IssueSeverity(""))}, wantInvalid: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			next, changes, err := applyUpdate(baseIssue(), tt.in)
			var inv *InvalidError
			if tt.wantInvalid {
				if !errors.As(err, &inv) {
					t.Fatalf("want InvalidError, got %v", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			var fields []string
			for _, c := range changes {
				fields = append(fields, c.Field)
			}
			if !reflect.DeepEqual(fields, tt.wantFields) {
				t.Errorf("changed fields = %v, want %v", fields, tt.wantFields)
			}
			if next.Version != tt.wantVersion {
				t.Errorf("version = %d, want %d", next.Version, tt.wantVersion)
			}
		})
	}
}

func TestApplyUpdateRecordsOldAndNew(t *testing.T) {
	_, changes, err := applyUpdate(baseIssue(), UpdateIssueInput{Status: ptr(store.IssueClosed)})
	if err != nil {
		t.Fatal(err)
	}
	want := []store.FieldChange{{Field: "status", Old: "open", New: "closed"}}
	if !reflect.DeepEqual(changes, want) {
		t.Errorf("changes = %#v, want %#v", changes, want)
	}
}

func TestNextPackStatus(t *testing.T) {
	tests := []struct {
		current   store.PackStatus
		succeeded bool
		open      int
		want      store.PackStatus
	}{
		{store.PackOpen, false, 0, store.PackOpen},           // never reviewed
		{store.PackOpen, true, 2, store.PackOpen},            // open issues
		{store.PackOpen, true, 0, store.PackResolved},        // all closed
		{store.PackResolved, true, 1, store.PackOpen},        // reopened or added
		{store.PackApproved, true, 1, store.PackApproved},    // final
		{store.PackCancelled, false, 0, store.PackCancelled}, // final
	}
	for _, tt := range tests {
		if got := nextPackStatus(tt.current, tt.succeeded, tt.open); got != tt.want {
			t.Errorf("nextPackStatus(%s, %v, %d) = %s, want %s", tt.current, tt.succeeded, tt.open, got, tt.want)
		}
	}
}

func TestHubCoalescesSignals(t *testing.T) {
	h := NewHub(nil)
	a := h.Subscribe("p1")
	b := h.Subscribe("p2")
	defer b.Close()

	h.dispatch("p1", Changes{Run: true})
	h.dispatch("p1", Changes{Issues: true})
	select {
	case <-a.Ready():
	default:
		t.Fatal("p1 subscriber not signalled")
	}
	if got := a.Take(); got != (Changes{Issues: true, Run: true}) {
		t.Errorf("Take = %+v", got)
	}
	if got := a.Take(); got.any() {
		t.Errorf("second Take = %+v, want empty", got)
	}
	select {
	case <-b.Ready():
		t.Fatal("p2 subscriber signalled for p1")
	default:
	}

	a.Close()
	h.dispatchAll(allChanged)
	if got := b.Take(); got != allChanged {
		t.Errorf("after dispatchAll, p2 Take = %+v", got)
	}
	if len(h.subs) != 1 {
		t.Errorf("closed subscription still registered: %v", h.subs)
	}
}

func TestIsText(t *testing.T) {
	tests := []struct {
		mime, name string
		want       bool
	}{
		{"text/markdown", "Material submittal.md", true},
		{"text/plain; charset=utf-8", "notes.txt", true},
		{"", "notes.md", true},
		{"application/octet-stream", "notes.md", true},
		{"application/pdf", "spec.pdf", false},
		{"application/pdf", "trick.md", false},
	}
	for _, tt := range tests {
		if got := isText(tt.mime, tt.name); got != tt.want {
			t.Errorf("isText(%q, %q) = %v, want %v", tt.mime, tt.name, got, tt.want)
		}
	}
}
