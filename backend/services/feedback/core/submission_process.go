package core

import (
	"context"
	"fmt"
	"log/slog"
	"slices"
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

	var updated []int64
	var err error
	if in.Processed {
		updated, err = s.db.Queries().MarkSubmissionsProcessed(ctx, ids)
	} else {
		updated, err = s.db.Queries().UnmarkSubmissionsProcessed(ctx, ids)
	}
	if err != nil {
		return SetProcessedResult{}, fmt.Errorf("set processed: %w", err)
	}

	existing, err := s.db.Queries().GetExistingSubmissionIDs(ctx, ids)
	if err != nil {
		return SetProcessedResult{}, fmt.Errorf("resolve submission ids: %w", err)
	}

	updatedSet := make(map[int64]struct{}, len(updated))
	for _, id := range updated {
		updatedSet[id] = struct{}{}
	}
	existingSet := make(map[int64]struct{}, len(existing))
	for _, id := range existing {
		existingSet[id] = struct{}{}
	}

	// Empty slices, not nil: the handler marshals these directly and the
	// contract promises [] over null.
	res := SetProcessedResult{Updated: []int64{}, Unchanged: []int64{}, NotFound: []int64{}}
	for _, id := range ids {
		switch {
		case contains(updatedSet, id):
			res.Updated = append(res.Updated, id)
		case contains(existingSet, id):
			res.Unchanged = append(res.Unchanged, id)
		default:
			res.NotFound = append(res.NotFound, id)
		}
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

func contains(set map[int64]struct{}, id int64) bool {
	_, ok := set[id]
	return ok
}
