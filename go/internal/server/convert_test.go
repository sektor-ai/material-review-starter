package server

import (
	"encoding/json"
	"testing"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/structpb"

	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

// changeValue only handles plain JSON types: it relies on change values
// having been read back from issue_events.changes (jsonb), which the store
// does for every event it returns. This pins that contract: each value goes
// through the same JSON round trip as the jsonb column before rendering.
func TestChangeValueAfterJSONBRoundTrip(t *testing.T) {
	page := int32(660)
	tests := []struct {
		name  string
		field string
		value any
		want  *structpb.Value
	}{
		{"null old value", "title", nil, structpb.NewNullValue()},
		{"plain string", "title", "w/c ratio 0.55 > 0.50", structpb.NewStringValue("w/c ratio 0.55 > 0.50")},
		{"status uses the proto enum name", "status", string(store.IssueClosed), structpb.NewStringValue("ISSUE_STATUS_CLOSED")},
		{"severity uses the proto enum name", "severity", string(store.SeverityCritical), structpb.NewStringValue("ISSUE_SEVERITY_CRITICAL")},
		{"spec_ref is an object", "spec_ref",
			store.SpecRef{Section: "05", Part: "06", Clause: "Table 6.4", PDFPage: &page},
			structpb.NewStructValue(&structpb.Struct{Fields: map[string]*structpb.Value{
				"section":      structpb.NewStringValue("05"),
				"part":         structpb.NewStringValue("06"),
				"clause":       structpb.NewStringValue("Table 6.4"),
				"clause_title": structpb.NewStringValue(""),
				"pdf_page":     structpb.NewNumberValue(660),
			}})},
		{"spec_ref without a page", "spec_ref",
			store.SpecRef{Section: "18", Part: "05", Clause: "5.3"},
			structpb.NewStructValue(&structpb.Struct{Fields: map[string]*structpb.Value{
				"section":      structpb.NewStringValue("18"),
				"part":         structpb.NewStringValue("05"),
				"clause":       structpb.NewStringValue("5.3"),
				"clause_title": structpb.NewStringValue(""),
				"pdf_page":     structpb.NewNullValue(),
			}})},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := changeValue(tt.field, jsonbRoundTrip(t, tt.field, tt.value))
			if !proto.Equal(got, tt.want) {
				t.Errorf("changeValue(%q) = %v, want %v", tt.field, got, tt.want)
			}
		})
	}
}

// jsonbRoundTrip stores v as a FieldChange the way the store writes
// issue_events.changes and decodes it the way pgx reads jsonb back.
func jsonbRoundTrip(t *testing.T, field string, v any) any {
	t.Helper()
	b, err := json.Marshal([]store.FieldChange{{Field: field, New: v}})
	if err != nil {
		t.Fatal(err)
	}
	var back []store.FieldChange
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	return back[0].New
}
