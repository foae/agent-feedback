package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"agent-feedback/backend/services/feedback/storage/postgres/sqlc"
)

// CreateReview validates and stores a review submission (multi-llm-review, second-opinion, ...).
//
// Idempotent on (submission_type, run_id): if a submission with the same skill and
// run_id was already stored, the existing row is returned with replayed=true instead
// of inserting a duplicate. The identity primary key cannot be targeted by
// ON CONFLICT DO UPDATE SET id = ..., so idempotency is implemented as
// check-then-insert-with-DO-NOTHING-then-recheck rather than a single upsert query.
func (s *Service) CreateReview(ctx context.Context, in CreateReviewInput) (sqlc.Submission, bool, error) {
	skill := strings.TrimSpace(in.Skill)
	machineName := strings.TrimSpace(in.MachineName)
	coordinatorModel := strings.TrimSpace(in.CoordinatorModel)
	runID := strings.TrimSpace(in.RunID)

	if skill == "" {
		return sqlc.Submission{}, false, fmt.Errorf("%w: skill is required", ErrInvalidInput)
	}
	if skill == "friction" {
		return sqlc.Submission{}, false, fmt.Errorf("%w: skill \"friction\" is reserved for friction submissions", ErrInvalidInput)
	}
	if machineName == "" {
		return sqlc.Submission{}, false, fmt.Errorf("%w: machine_name is required", ErrInvalidInput)
	}
	if coordinatorModel == "" {
		return sqlc.Submission{}, false, fmt.Errorf("%w: coordinator_model is required", ErrInvalidInput)
	}
	if runID == "" {
		return sqlc.Submission{}, false, fmt.Errorf("%w: run_id is required", ErrInvalidInput)
	}
	if len(in.Reviewers) == 0 {
		return sqlc.Submission{}, false, fmt.Errorf("%w: reviewers must be non-empty", ErrInvalidInput)
	}
	for i, rv := range in.Reviewers {
		if strings.TrimSpace(rv.Slot) == "" {
			return sqlc.Submission{}, false, fmt.Errorf("%w: reviewers[%d].slot is required", ErrInvalidInput, i)
		}
		if strings.TrimSpace(rv.Model) == "" {
			return sqlc.Submission{}, false, fmt.Errorf("%w: reviewers[%d].model is required", ErrInvalidInput, i)
		}
		if strings.TrimSpace(rv.Status) == "" {
			return sqlc.Submission{}, false, fmt.Errorf("%w: reviewers[%d].status is required", ErrInvalidInput, i)
		}
		if rv.DurationS != nil && *rv.DurationS < 0 {
			return sqlc.Submission{}, false, fmt.Errorf("%w: reviewers[%d].duration_s must be >= 0", ErrInvalidInput, i)
		}
		if rv.Bytes != nil && *rv.Bytes < 0 {
			return sqlc.Submission{}, false, fmt.Errorf("%w: reviewers[%d].bytes must be >= 0", ErrInvalidInput, i)
		}
		if rv.Score != nil && (*rv.Score < 1 || *rv.Score > 5) {
			return sqlc.Submission{}, false, fmt.Errorf("%w: reviewers[%d].score must be between 1 and 5", ErrInvalidInput, i)
		}
		if rv.Valid != nil && *rv.Valid < 0 {
			return sqlc.Submission{}, false, fmt.Errorf("%w: reviewers[%d].valid must be >= 0", ErrInvalidInput, i)
		}
		if rv.Invalid != nil && *rv.Invalid < 0 {
			return sqlc.Submission{}, false, fmt.Errorf("%w: reviewers[%d].invalid must be >= 0", ErrInvalidInput, i)
		}
	}

	// Idempotent replay: an existing submission with this (skill, run_id) wins.
	existing, err := s.db.Queries().GetSubmissionByTypeAndRunID(ctx, sqlc.GetSubmissionByTypeAndRunIDParams{
		SubmissionType: skill,
		RunID:          pgtype.Text{String: runID, Valid: true},
	})
	if err == nil {
		return existing, true, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return sqlc.Submission{}, false, fmt.Errorf("check existing submission: %w", err)
	}

	payload, err := json.Marshal(reviewPayload{
		Prompt:    in.Prompt,
		Reviewers: in.Reviewers,
	})
	if err != nil {
		return sqlc.Submission{}, false, fmt.Errorf("marshal review payload: %w", err)
	}

	created, err := s.db.Queries().CreateSubmission(ctx, sqlc.CreateSubmissionParams{
		SubmissionType:   skill,
		MachineName:      machineName,
		CoordinatorModel: coordinatorModel,
		RunID:            pgtype.Text{String: runID, Valid: true},
		Payload:          payload,
	})
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return sqlc.Submission{}, false, fmt.Errorf("create review submission: %w", err)
		}
		// ON CONFLICT DO NOTHING returns pgx.ErrNoRows when a concurrent request won
		// the race. Re-fetch and return the winner's row as a replay.
		existing, getErr := s.db.Queries().GetSubmissionByTypeAndRunID(ctx, sqlc.GetSubmissionByTypeAndRunIDParams{
			SubmissionType: skill,
			RunID:          pgtype.Text{String: runID, Valid: true},
		})
		if getErr == nil {
			return existing, true, nil
		}
		return sqlc.Submission{}, false, fmt.Errorf("create review submission: %w", err)
	}

	slog.InfoContext(ctx, "review submission created",
		"submission_id", created.ID, "skill", skill, "machine_name", machineName, "run_id", runID)

	return created, false, nil
}

// CreateFriction validates and stores a friction submission. Frictions have no
// run_id (no dedupe key) so every call creates a new row.
func (s *Service) CreateFriction(ctx context.Context, in CreateFrictionInput) (sqlc.Submission, error) {
	machineName := strings.TrimSpace(in.MachineName)
	coordinatorModel := strings.TrimSpace(in.CoordinatorModel)
	category := strings.TrimSpace(in.Category)
	summary := strings.TrimSpace(in.Summary)

	if machineName == "" {
		return sqlc.Submission{}, fmt.Errorf("%w: machine_name is required", ErrInvalidInput)
	}
	if coordinatorModel == "" {
		return sqlc.Submission{}, fmt.Errorf("%w: coordinator_model is required", ErrInvalidInput)
	}
	if category == "" {
		return sqlc.Submission{}, fmt.Errorf("%w: category is required", ErrInvalidInput)
	}
	if summary == "" {
		return sqlc.Submission{}, fmt.Errorf("%w: summary is required", ErrInvalidInput)
	}

	payload, err := json.Marshal(frictionPayload{
		Category:     category,
		Summary:      summary,
		Details:      in.Details,
		SuggestedFix: in.SuggestedFix,
		Project:      in.Project,
		Harness:      in.Harness,
	})
	if err != nil {
		return sqlc.Submission{}, fmt.Errorf("marshal friction payload: %w", err)
	}

	created, err := s.db.Queries().CreateSubmission(ctx, sqlc.CreateSubmissionParams{
		SubmissionType:   "friction",
		MachineName:      machineName,
		CoordinatorModel: coordinatorModel,
		RunID:            pgtype.Text{},
		Payload:          payload,
	})
	if err != nil {
		return sqlc.Submission{}, fmt.Errorf("create friction submission: %w", err)
	}

	slog.InfoContext(ctx, "friction submission created",
		"submission_id", created.ID, "machine_name", machineName, "category", category)

	return created, nil
}
