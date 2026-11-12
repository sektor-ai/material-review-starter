package main

import (
	"strings"
	"testing"

	"github.com/sektor-ai/material-review-starter/go/internal/config"
)

func TestNamesFor(t *testing.T) {
	cfg := config.Config{
		DatabaseURL: "postgres://postgres:secret@localhost:5433/doc_review?sslmode=disable",
		S3:          config.S3{Bucket: "documents"},
	}
	got, err := namesFor(cfg, "upload-form")
	if err != nil {
		t.Fatal(err)
	}
	want := envNames{
		database:    "doc_review_wt_upload_form",
		databaseURL: "postgres://postgres:secret@localhost:5433/doc_review_wt_upload_form?sslmode=disable",
		bucket:      "documents-wt-upload-form",
	}
	if got != want {
		t.Fatalf("namesFor = %+v, want %+v", got, want)
	}
}

// slugPattern must agree with SLUG_PATTERN in tools/wt/lib/common.sh; tools/wt/test_resolve.sh runs
// the same cases against the bash side.
func TestSlugPattern(t *testing.T) {
	valid := []string{"a", "ab", "a-b", "a--b", "upload-form", "9x", strings.Repeat("a", 39)}
	invalid := []string{"", "a-", "-a", "A", "foo_bar", "a b", strings.Repeat("a", 40)}
	for _, s := range valid {
		if !slugPattern.MatchString(s) {
			t.Errorf("slug %q rejected, want accepted", s)
		}
	}
	for _, s := range invalid {
		if slugPattern.MatchString(s) {
			t.Errorf("slug %q accepted, want rejected", s)
		}
	}
}

func TestRequireLocal(t *testing.T) {
	tests := []struct {
		name    string
		dbURL   string
		s3      string
		wantErr bool
	}{
		{"local postgres and minio", "postgres://u:p@localhost:5433/db", "localhost:9000", false},
		{"loopback ip", "postgres://u:p@127.0.0.1:5433/db", "127.0.0.1:9000", false},
		{"remote database", "postgres://u:p@10.0.0.5:5432/db", "localhost:9000", true},
		{"remote object storage", "postgres://u:p@localhost:5433/db", "storage.googleapis.com", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := config.Config{DatabaseURL: tt.dbURL, S3: config.S3{Endpoint: tt.s3}}
			if err := requireLocal(cfg); (err != nil) != tt.wantErr {
				t.Fatalf("requireLocal error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
