package service

import (
	"errors"
	"fmt"

	"github.com/google/uuid"

	"github.com/sektor-ai/material-review-starter/go/internal/store"
)

// Errors the transport layer maps to status codes.
var (
	ErrNotFound      = store.ErrNotFound
	ErrAlreadyExists = store.ErrAlreadyExists
)

// InvalidError: the request itself is wrong (InvalidArgument).
type InvalidError struct{ Msg string }

func (e *InvalidError) Error() string { return e.Msg }

func invalid(format string, args ...any) error {
	return &InvalidError{Msg: fmt.Sprintf(format, args...)}
}

// PreconditionError: the request is valid but the current state does not
// allow it (FailedPrecondition).
type PreconditionError struct{ Msg string }

func (e *PreconditionError) Error() string { return e.Msg }

func precondition(format string, args ...any) error {
	return &PreconditionError{Msg: fmt.Sprintf(format, args...)}
}

// ConflictError: an issue update named a stale version (Aborted). Current is
// the issue as it is now.
type ConflictError struct{ Current store.Issue }

func (e *ConflictError) Error() string {
	return fmt.Sprintf("issue %s is at version %d", e.Current.ID, e.Current.Version)
}

// checkID rejects ids that are not UUIDs, so they fail as InvalidArgument
// instead of reaching the database.
func checkID(field, id string) error {
	if id == "" {
		return invalid("%s is required", field)
	}
	if _, err := uuid.Parse(id); err != nil {
		return invalid("%s is not a valid id", field)
	}
	return nil
}

func packFinal(p store.Pack) error {
	if p.Status.Final() {
		return precondition("pack %s is %s and can no longer change", p.SubmittalNo, p.Status)
	}
	return nil
}

func notFoundAs(err error, msg string) error {
	if errors.Is(err, store.ErrNotFound) {
		return fmt.Errorf("%s: %w", msg, store.ErrNotFound)
	}
	return err
}
