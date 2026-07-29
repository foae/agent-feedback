package core

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"

	"agent-feedback/backend/services/feedback/storage/postgres/sqlc"
)

// GetSubmission retrieves a submission by ID, including its full payload.
func (s *Service) GetSubmission(ctx context.Context, id int64) (sqlc.Submission, error) {
	sub, err := s.db.Queries().GetSubmissionByID(ctx, id)
	if err != nil {
		if err == pgx.ErrNoRows {
			return sqlc.Submission{}, ErrSubmissionNotFound
		}
		return sqlc.Submission{}, fmt.Errorf("get submission: %w", err)
	}

	return sub, nil
}
