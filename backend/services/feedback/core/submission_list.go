package core

import (
	"context"
	"fmt"
	"math"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"agent-feedback/backend/services/feedback/storage/postgres/sqlc"
)

const (
	defaultListLimit = 50
	maxListLimit     = 500
)

// ListSubmissionsInput holds optional filters for ListSubmissions. Zero values (nil,
// empty string) mean "no filter".
type ListSubmissionsInput struct {
	Type    string
	Machine string
	Model   string
	Since   *time.Time
	Until   *time.Time
	Limit   int
	Offset  int
}

// ListSubmissions returns submissions matching the given filters, ordered newest
// first, without the payload column.
func (s *Service) ListSubmissions(ctx context.Context, in ListSubmissionsInput) ([]sqlc.ListSubmissionsRow, error) {
	limit, offset := NormalizeListWindow(in.Limit, in.Offset)

	params := sqlc.ListSubmissionsParams{
		SubmissionType:   textParam(in.Type),
		MachineName:      textParam(in.Machine),
		CoordinatorModel: textParam(in.Model),
		Since:            timestampParam(in.Since),
		Until:            timestampParam(in.Until),
		Limit:            int32(limit),
		Offset:           int32(offset),
	}

	rows, err := s.db.Queries().ListSubmissions(ctx, params)
	if err != nil {
		return nil, fmt.Errorf("list submissions: %w", err)
	}

	if rows == nil {
		rows = []sqlc.ListSubmissionsRow{}
	}

	return rows, nil
}

// NormalizeListWindow clamps limit and offset to the same bounds ListSubmissions
// applies internally, so callers (e.g. the HTTP handler) can echo back the values
// that were actually used for the query.
func NormalizeListWindow(limit, offset int) (int, int) {
	if limit <= 0 {
		limit = defaultListLimit
	}
	if limit > maxListLimit {
		limit = maxListLimit
	}

	if offset < 0 {
		offset = 0
	}
	if offset > math.MaxInt32 {
		offset = math.MaxInt32
	}

	return limit, offset
}

func textParam(v string) pgtype.Text {
	if v == "" {
		return pgtype.Text{}
	}
	return pgtype.Text{String: v, Valid: true}
}

func timestampParam(t *time.Time) pgtype.Timestamptz {
	if t == nil {
		return pgtype.Timestamptz{}
	}
	return pgtype.Timestamptz{Time: *t, Valid: true}
}
