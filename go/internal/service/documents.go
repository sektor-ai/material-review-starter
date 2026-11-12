package service

import (
	"context"
	"crypto/sha256"
	"fmt"
	"path"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/sektor-ai/material-review-starter/go/internal/storage"
	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

// MaxDocumentBytes is the largest original file UploadDocument accepts.
const MaxDocumentBytes = 20 << 20

// Documents stores originals in object storage and parsed text in Postgres.
type Documents struct {
	st    *store.Store
	files *storage.Storage
}

func NewDocuments(st *store.Store, files *storage.Storage) *Documents {
	return &Documents{st: st, files: files}
}

type UploadInput struct {
	PackID   string
	Filename string
	MimeType string
	Content  []byte
	Title    string
}

// Upload stores the original and parses it. Markdown and plain text become
// READY. Other types are stored as FAILED for now: there is no parser for
// them yet, so they would otherwise stay PROCESSING forever.
func (d *Documents) Upload(ctx context.Context, actor store.User, in UploadInput) (store.Document, error) {
	if err := checkID("pack_id", in.PackID); err != nil {
		return store.Document{}, err
	}
	filename := path.Base(strings.ReplaceAll(strings.TrimSpace(in.Filename), `\`, "/"))
	if filename == "" || filename == "." || filename == "/" {
		return store.Document{}, invalid("filename is required")
	}
	if len(in.Content) == 0 {
		return store.Document{}, invalid("content is empty")
	}
	if len(in.Content) > MaxDocumentBytes {
		return store.Document{}, invalid("file is larger than %d MB", MaxDocumentBytes>>20)
	}
	title := strings.TrimSpace(in.Title)
	if title == "" {
		title = strings.TrimSuffix(filename, path.Ext(filename))
	}
	mimeType := strings.TrimSpace(in.MimeType)
	if mimeType == "" {
		mimeType = mimeFromName(filename)
	}

	// Fail fast before writing to object storage; checked again under the lock.
	pack, err := d.st.GetPack(ctx, in.PackID)
	if err != nil {
		return store.Document{}, notFoundAs(err, "pack")
	}
	if err := packFinal(pack); err != nil {
		return store.Document{}, err
	}

	id := uuid.NewString()
	key := fmt.Sprintf("packs/%s/documents/%s", in.PackID, id)
	if err := d.files.Upload(ctx, key, in.Content, mimeType); err != nil {
		return store.Document{}, err
	}

	sum := sha256.Sum256(in.Content)
	doc := store.NewDocument{
		ID: id, Filename: filename, Title: title, MimeType: mimeType,
		SizeBytes: int64(len(in.Content)), SHA256: sum[:], StorageKey: key, CreatedBy: actor.ID,
	}
	switch {
	case !isText(mimeType, filename):
		doc.Status = store.DocumentFailed
		doc.ParseError = fmt.Sprintf("parsing %s is not supported yet; upload Markdown or plain text", mimeType)
	case !utf8.Valid(in.Content):
		doc.Status = store.DocumentFailed
		doc.ParseError = "the file is not valid UTF-8 text"
	default:
		text := string(in.Content)
		doc.Status, doc.Content = store.DocumentReady, &text
	}

	var out store.Document
	err = d.st.InPack(ctx, in.PackID, func(tx *store.PackTx) error {
		if err := packFinal(tx.Pack()); err != nil {
			return err
		}
		var err error
		if out, err = tx.InsertDocument(ctx, doc); err != nil {
			return err
		}
		return tx.NotifyPack(ctx) // document_count changed
	})
	// On error the uploaded object is left orphaned under a key nothing
	// references; acceptable for now.
	return out, notFoundAs(err, "pack")
}

// Get returns a document and its parsed text.
func (d *Documents) Get(ctx context.Context, id string) (store.Document, string, error) {
	if err := checkID("id", id); err != nil {
		return store.Document{}, "", err
	}
	doc, err := d.st.GetDocument(ctx, id)
	if err != nil {
		return store.Document{}, "", notFoundAs(err, "document")
	}
	content, err := d.st.DocumentContent(ctx, id)
	if err != nil {
		return store.Document{}, "", err
	}
	return doc, content, nil
}

// Original returns a document and its original file.
func (d *Documents) Original(ctx context.Context, id string) (store.Document, []byte, error) {
	if err := checkID("id", id); err != nil {
		return store.Document{}, nil, err
	}
	doc, err := d.st.GetDocument(ctx, id)
	if err != nil {
		return store.Document{}, nil, notFoundAs(err, "document")
	}
	body, _, err := d.files.Get(ctx, doc.StorageKey)
	if err != nil {
		return store.Document{}, nil, err
	}
	return doc, body, nil
}

func isText(mimeType, filename string) bool {
	base := strings.ToLower(strings.TrimSpace(strings.Split(mimeType, ";")[0]))
	switch base {
	case "text/markdown", "text/x-markdown", "text/plain":
		return true
	}
	switch strings.ToLower(path.Ext(filename)) {
	case ".md", ".markdown", ".txt":
		return base == "" || base == "application/octet-stream"
	}
	return false
}

func mimeFromName(filename string) string {
	switch strings.ToLower(path.Ext(filename)) {
	case ".md", ".markdown":
		return "text/markdown"
	case ".txt":
		return "text/plain"
	case ".pdf":
		return "application/pdf"
	}
	return "application/octet-stream"
}
