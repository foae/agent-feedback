package handler

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"agent-feedback/backend/services/feedback/storage/postgres/sqlc"
)

// maxRequestBytes caps the size of a decoded request body.
const maxRequestBytes = 10 << 20

func writeJSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, status int, errType, message string) {
	writeJSON(w, status, ErrorResponse{
		Error:   errType,
		Message: message,
	})
}

// submissionToResponse converts a sqlc.Submission to its full API response,
// including the decoded payload.
func submissionToResponse(sub sqlc.Submission) (SubmissionResponse, error) {
	var payload map[string]any
	if len(sub.Payload) > 0 {
		if err := json.Unmarshal(sub.Payload, &payload); err != nil {
			return SubmissionResponse{}, err
		}
	}

	return SubmissionResponse{
		ID:               sub.ID,
		SubmissionType:   sub.SubmissionType,
		MachineName:      sub.MachineName,
		CoordinatorModel: sub.CoordinatorModel,
		RunID:            textToStringPtr(sub.RunID),
		Payload:          payload,
		CreatedAt:        sub.CreatedAt.Time,
		ProcessedAt:      timestamptzToTimePtr(sub.ProcessedAt),
	}, nil
}

// submissionToSummary converts a sqlc.ListSubmissionsRow to the list response DTO.
func submissionToSummary(row sqlc.ListSubmissionsRow) SubmissionSummaryResponse {
	return SubmissionSummaryResponse{
		ID:               row.ID,
		SubmissionType:   row.SubmissionType,
		MachineName:      row.MachineName,
		CoordinatorModel: row.CoordinatorModel,
		RunID:            textToStringPtr(row.RunID),
		CreatedAt:        row.CreatedAt.Time,
		ProcessedAt:      timestamptzToTimePtr(row.ProcessedAt),
		Category:         row.FrictionCategory,
		Summary:          row.FrictionSummary,
		Project:          row.FrictionProject,
		Harness:          row.FrictionHarness,
	}
}

func textToStringPtr(t pgtype.Text) *string {
	if !t.Valid {
		return nil
	}
	return &t.String
}

func timestamptzToTimePtr(t pgtype.Timestamptz) *time.Time {
	if !t.Valid {
		return nil
	}
	return &t.Time
}
