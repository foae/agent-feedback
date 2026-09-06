package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"agent-feedback/backend/services/feedback/storage/postgres/sqlc"
)

// Generous upper bounds. They keep indexed columns under Postgres's B-tree
// entry limit and stop garbage rows — they do not police content. details,
// suggested_fix, prompt, and output are bounded only by the 10 MiB request cap;
// submitting feedback must stay easy.
const (
	maxIdentifierLen = 200  // machine_name, coordinator_model, run_id, skill, category, project, harness, slot, model, status
	maxSummaryLen    = 2000 // friction summary
	maxNoteLen       = 4000 // reviewer note
	maxReviewers     = 100

	maxContextEntries  = 32
	maxContextKeyLen   = 64
	maxContextValueLen = 2000
)

// frictionDedupeWindow is how far back CreateFriction looks for an
// identical-content friction before absorbing the new one as a duplicate.
// Package variable so integration tests can shrink it.
var frictionDedupeWindow = 24 * time.Hour

func fieldTooLong(field, v string, maxLen int) error {
	if len(v) > maxLen {
		return fmt.Errorf("%w: %s exceeds %d bytes", ErrInvalidInput, field, maxLen)
	}
	return nil
}

// validateContext caps the auto-collected client metadata map. Keys are
// free-form (clients may add new ones without a server change); only sizes
// are enforced.
func validateContext(ctx map[string]string) error {
	if len(ctx) > maxContextEntries {
		return fmt.Errorf("%w: context has more than %d entries", ErrInvalidInput, maxContextEntries)
	}
	for k, v := range ctx {
		if k == "" {
			return fmt.Errorf("%w: context keys must be non-empty", ErrInvalidInput)
		}
		if len(k) > maxContextKeyLen {
			return fmt.Errorf("%w: context key %q exceeds %d bytes", ErrInvalidInput, k[:maxContextKeyLen], maxContextKeyLen)
		}
		if len(v) > maxContextValueLen {
			return fmt.Errorf("%w: context value for %q exceeds %d bytes", ErrInvalidInput, k, maxContextValueLen)
		}
	}
	return nil
}

// CreateReview validates and stores a review submission (multi-llm-review, second-opinion, ...).
//
// Idempotent on (submission_type, run_id): replaying identical content returns
// the existing row with replayed=true; replaying different content under the
// same key returns ErrReplayMismatch (409) instead of silently discarding the
// new payload. The identity primary key cannot be targeted by ON CONFLICT DO
// UPDATE SET id = ..., so idempotency is implemented as
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
	for field, v := range map[string]string{
		"skill": skill, "machine_name": machineName, "coordinator_model": coordinatorModel, "run_id": runID,
	} {
		if err := fieldTooLong(field, v, maxIdentifierLen); err != nil {
			return sqlc.Submission{}, false, err
		}
	}
	if len(in.Reviewers) == 0 {
		return sqlc.Submission{}, false, fmt.Errorf("%w: reviewers must be non-empty", ErrInvalidInput)
	}
	if len(in.Reviewers) > maxReviewers {
		return sqlc.Submission{}, false, fmt.Errorf("%w: at most %d reviewers per submission", ErrInvalidInput, maxReviewers)
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
		for field, v := range map[string]string{"slot": rv.Slot, "model": rv.Model, "status": rv.Status} {
			if err := fieldTooLong(fmt.Sprintf("reviewers[%d].%s", i, field), v, maxIdentifierLen); err != nil {
				return sqlc.Submission{}, false, err
			}
		}
		if err := fieldTooLong(fmt.Sprintf("reviewers[%d].note", i), rv.Note, maxNoteLen); err != nil {
			return sqlc.Submission{}, false, err
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

	payloadShape := reviewPayload{
		Prompt:    in.Prompt,
		Reviewers: in.Reviewers,
	}
	hash, err := canonicalHash(reviewCanonical{
		MachineName:      machineName,
		CoordinatorModel: coordinatorModel,
		Payload:          payloadShape,
	})
	if err != nil {
		return sqlc.Submission{}, false, fmt.Errorf("hash review payload: %w", err)
	}

	// Idempotent replay: identical content returns the existing row; different
	// content under the same (skill, run_id) is a mismatch, never a silent discard.
	existing, err := s.db.Queries().GetSubmissionByTypeAndRunID(ctx, sqlc.GetSubmissionByTypeAndRunIDParams{
		SubmissionType: skill,
		RunID:          pgtype.Text{String: runID, Valid: true},
	})
	if err == nil {
		return replayOrMismatch(existing, hash)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return sqlc.Submission{}, false, fmt.Errorf("check existing submission: %w", err)
	}

	payload, err := json.Marshal(payloadShape)
	if err != nil {
		return sqlc.Submission{}, false, fmt.Errorf("marshal review payload: %w", err)
	}

	created, err := s.db.Queries().CreateSubmission(ctx, sqlc.CreateSubmissionParams{
		SubmissionType:   skill,
		MachineName:      machineName,
		CoordinatorModel: coordinatorModel,
		RunID:            pgtype.Text{String: runID, Valid: true},
		Payload:          payload,
		PayloadHash:      pgtype.Text{String: hash, Valid: true},
	})
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return sqlc.Submission{}, false, fmt.Errorf("create review submission: %w", err)
		}
		// ON CONFLICT DO NOTHING returns pgx.ErrNoRows when a concurrent request won
		// the race. Re-fetch and treat the winner's row as a replay (or mismatch).
		existing, getErr := s.db.Queries().GetSubmissionByTypeAndRunID(ctx, sqlc.GetSubmissionByTypeAndRunIDParams{
			SubmissionType: skill,
			RunID:          pgtype.Text{String: runID, Valid: true},
		})
		if getErr == nil {
			return replayOrMismatch(existing, hash)
		}
		return sqlc.Submission{}, false, fmt.Errorf("create review submission: %w", err)
	}

	slog.InfoContext(ctx, "review submission created",
		"submission_id", created.ID, "skill", skill, "machine_name", machineName, "run_id", runID)

	return created, false, nil
}

// replayOrMismatch decides whether an existing (skill, run_id) row is an
// identical-content replay (returned as-is with replayed=true) or a content
// mismatch (ErrReplayMismatch, 409 upstream). Rows created before payload_hash
// existed have no hash and keep the legacy behavior: replay without comparison.
func replayOrMismatch(existing sqlc.Submission, hash string) (sqlc.Submission, bool, error) {
	if existing.PayloadHash.Valid && existing.PayloadHash.String != hash {
		return sqlc.Submission{}, false, fmt.Errorf(
			"%w: run_id already stored as submission %d with different content; submit the correction as a new submission (new run_id)",
			ErrReplayMismatch, existing.ID)
	}
	return existing, true, nil
}

// CreateFriction validates and stores a friction submission. Frictions have no
// run_id; instead, an identical-content friction submitted within
// frictionDedupeWindow is absorbed as a duplicate — the existing row is
// returned with duplicate=true and no new row is inserted. Blind retries are
// therefore safe within the window, with zero client cooperation required.
func (s *Service) CreateFriction(ctx context.Context, in CreateFrictionInput) (sqlc.Submission, bool, error) {
	machineName := strings.TrimSpace(in.MachineName)
	coordinatorModel := strings.TrimSpace(in.CoordinatorModel)
	category := strings.TrimSpace(in.Category)
	summary := strings.TrimSpace(in.Summary)

	if machineName == "" {
		return sqlc.Submission{}, false, fmt.Errorf("%w: machine_name is required", ErrInvalidInput)
	}
	if coordinatorModel == "" {
		return sqlc.Submission{}, false, fmt.Errorf("%w: coordinator_model is required", ErrInvalidInput)
	}
	if category == "" {
		return sqlc.Submission{}, false, fmt.Errorf("%w: category is required", ErrInvalidInput)
	}
	if summary == "" {
		return sqlc.Submission{}, false, fmt.Errorf("%w: summary is required", ErrInvalidInput)
	}
	for field, v := range map[string]string{
		"machine_name": machineName, "coordinator_model": coordinatorModel,
		"category": category, "project": in.Project, "harness": in.Harness,
	} {
		if err := fieldTooLong(field, v, maxIdentifierLen); err != nil {
			return sqlc.Submission{}, false, err
		}
	}
	if err := fieldTooLong("summary", summary, maxSummaryLen); err != nil {
		return sqlc.Submission{}, false, err
	}
	if err := validateContext(in.Context); err != nil {
		return sqlc.Submission{}, false, err
	}

	payloadShape := frictionPayload{
		Category:     category,
		Summary:      summary,
		Details:      in.Details,
		SuggestedFix: in.SuggestedFix,
		Project:      in.Project,
		Harness:      in.Harness,
		Context:      in.Context,
	}
	// The dedupe hash covers the semantic content only. Context (occurred_at,
	// commit, cwd, ...) varies between attempts of the SAME friction and must
	// not defeat duplicate absorption.
	content := payloadShape
	content.Context = nil
	hash, err := canonicalHash(frictionCanonical{
		MachineName:      machineName,
		CoordinatorModel: coordinatorModel,
		Payload:          content,
	})
	if err != nil {
		return sqlc.Submission{}, false, fmt.Errorf("hash friction payload: %w", err)
	}

	// Duplicate absorption must serialize the lookup and creation. The advisory
	// lock is acquired in its own statement; under READ COMMITTED the lookup
	// therefore observes a fresh snapshot after a waiter acquires the lock.
	payload, err := json.Marshal(payloadShape)
	if err != nil {
		return sqlc.Submission{}, false, fmt.Errorf("marshal friction payload: %w", err)
	}

	tx, err := s.db.DB().BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return sqlc.Submission{}, false, fmt.Errorf("begin friction dedupe: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	txDB := s.db.WithTx(tx)
	if err := txDB.Queries().LockFrictionDedupe(ctx, hash); err != nil {
		return sqlc.Submission{}, false, fmt.Errorf("lock friction dedupe: %w", err)
	}

	existing, err := txDB.Queries().GetRecentFrictionByHash(ctx, sqlc.GetRecentFrictionByHashParams{
		PayloadHash: pgtype.Text{String: hash, Valid: true},
		CreatedAt:   pgtype.Timestamptz{Time: time.Now().Add(-frictionDedupeWindow), Valid: true},
	})
	if err == nil {
		if err := tx.Commit(ctx); err != nil {
			return sqlc.Submission{}, false, fmt.Errorf("commit friction duplicate absorption: %w", err)
		}
		return existing, true, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return sqlc.Submission{}, false, fmt.Errorf("check duplicate friction: %w", err)
	}

	created, err := txDB.Queries().CreateSubmission(ctx, sqlc.CreateSubmissionParams{
		SubmissionType:   "friction",
		MachineName:      machineName,
		CoordinatorModel: coordinatorModel,
		RunID:            pgtype.Text{},
		Payload:          payload,
		PayloadHash:      pgtype.Text{String: hash, Valid: true},
	})
	if err != nil {
		return sqlc.Submission{}, false, fmt.Errorf("create friction submission: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return sqlc.Submission{}, false, fmt.Errorf("commit friction submission: %w", err)
	}

	slog.InfoContext(ctx, "friction submission created",
		"submission_id", created.ID, "machine_name", machineName, "category", category)

	return created, false, nil
}
