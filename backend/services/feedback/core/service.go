package core

import (
	"context"
	"errors"
	"fmt"

	"agent-feedback/backend/services/feedback/storage/postgres"
)

// Sentinel errors for the core layer. Handler maps these to HTTP status codes.
var (
	ErrSubmissionNotFound = errors.New("submission not found")
	ErrInvalidInput       = errors.New("invalid input")
	// ErrReplayMismatch: a review replay carried different content than the
	// stored (skill, run_id) row. Mapped to 409 — corrections are new
	// submissions, never silent discards.
	ErrReplayMismatch = errors.New("replay mismatch")
)

// Service encapsulates all dependencies needed for business logic execution.
type Service struct {
	db *postgres.Client
}

// New creates a new service instance with all dependencies.
func New(db *postgres.Client) (*Service, error) {
	ctx := context.Background()
	if err := db.DB().Ping(ctx); err != nil {
		return nil, fmt.Errorf("unable to ping DB: %w", err)
	}

	return &Service{
		db: db,
	}, nil
}

// Close releases all service resources.
func (s *Service) Close() {
	s.db.Close()
}
