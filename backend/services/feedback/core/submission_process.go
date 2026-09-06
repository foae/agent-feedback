package core

import (
	"context"
	"fmt"
	"log/slog"
	"slices"

	"github.com/jackc/pgx/v5"
)

const maxProcessedIDs = 500

// SetProcessedInput identifies submissions to mark (Processed=true) or unmark
// (Processed=false). processed_at is the only mutable submission state; the
// payload stays write-once.
type SetProcessedInput struct {
	IDs       []int64
	Processed bool
}

// SetProcessedResult classifies every requested id: Updated (state changed),
// Unchanged (already in the requested state), NotFound (no such submission).
// Marking is idempotent — the timestamp of the first marking is preserved.
type SetProcessedResult struct {
	Updated   []int64
	Unchanged []int64
	NotFound  []int64
}

// SetProcessed marks or unmarks submissions as processed, in one batch.
func (s *Service) SetProcessed(ctx context.Context, in SetProcessedInput) (SetProcessedResult, error) {
	if len(in.IDs) == 0 {
		return SetProcessedResult{}, fmt.Errorf("%w: ids must be non-empty", ErrInvalidInput)
	}
	if len(in.IDs) > maxProcessedIDs {
		return SetProcessedResult{}, fmt.Errorf("%w: at most %d ids per request", ErrInvalidInput, maxProcessedIDs)
	}
	seen := make(map[int64]struct{}, len(in.IDs))
	ids := make([]int64, 0, len(in.IDs))
	for _, id := range in.IDs {
		if id <= 0 {
			return SetProcessedResult{}, fmt.Errorf("%w: ids must be positive, got %d", ErrInvalidInput, id)
		}
		if _, dup := seen[id]; !dup {
			seen[id] = struct{}{}
			ids = append(ids, id)
		}
	}

	tx, err := s.db.DB().BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return SetProcessedResult{}, fmt.Errorf("begin set processed: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	queries := s.db.WithTx(tx).Queries()
	locked, err := queries.LockSubmissionProcessingStates(ctx, ids)
	if err != nil {
		return SetProcessedResult{}, fmt.Errorf("lock submission processing states: %w", err)
	}

	existing := make(map[int64]bool, len(locked))
	for _, row := range locked {
		existing[row.ID] = row.ProcessedAt.Valid
	}

	// Empty slices, not nil: the handler marshals these directly and the
	// contract promises [] over null.
	res := SetProcessedResult{Updated: []int64{}, Unchanged: []int64{}, NotFound: []int64{}}
	for _, id := range ids {
		processed, found := existing[id]
		switch {
		case !found:
			res.NotFound = append(res.NotFound, id)
		case processed == in.Processed:
			res.Unchanged = append(res.Unchanged, id)
		default:
			res.Updated = append(res.Updated, id)
		}
	}

	if len(res.Updated) > 0 {
		var err error
		if in.Processed {
			_, err = queries.MarkSubmissionsProcessed(ctx, res.Updated)
		} else {
			_, err = queries.UnmarkSubmissionsProcessed(ctx, res.Updated)
		}
		if err != nil {
			return SetProcessedResult{}, fmt.Errorf("set processed: %w", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return SetProcessedResult{}, fmt.Errorf("commit set processed: %w", err)
	}

	slices.Sort(res.Updated)
	slices.Sort(res.Unchanged)
	slices.Sort(res.NotFound)

	if len(res.Updated) > 0 {
		slog.InfoContext(ctx, "submissions processed state changed",
			"processed", in.Processed, "updated", res.Updated)
	}

	return res, nil
}
