package handler

import "time"

// ReviewerDTO is a single reviewer's contribution within a review submission.
type ReviewerDTO struct {
	Slot      string `json:"slot"`
	Model     string `json:"model"`
	Status    string `json:"status"`
	DurationS *int   `json:"duration_s,omitempty"`
	Bytes     *int   `json:"bytes,omitempty"`
	Output    string `json:"output,omitempty"`
	Score     *int   `json:"score,omitempty"`
	Valid     *int   `json:"valid,omitempty"`
	Invalid   *int   `json:"invalid,omitempty"`
	Note      string `json:"note,omitempty"`
}

// CreateReviewRequest is the request body for POST /api/v1/reviews.
type CreateReviewRequest struct {
	Skill            string        `json:"skill"`
	MachineName      string        `json:"machine_name"`
	CoordinatorModel string        `json:"coordinator_model"`
	RunID            string        `json:"run_id"`
	Prompt           string        `json:"prompt,omitempty"`
	Reviewers        []ReviewerDTO `json:"reviewers"`
}

// CreateFrictionRequest is the request body for POST /api/v1/frictions.
type CreateFrictionRequest struct {
	MachineName      string `json:"machine_name"`
	CoordinatorModel string `json:"coordinator_model"`
	Category         string `json:"category"`
	Summary          string `json:"summary"`
	Details          string `json:"details,omitempty"`
	SuggestedFix     string `json:"suggested_fix,omitempty"`
	Project          string `json:"project,omitempty"`
	Harness          string `json:"harness,omitempty"`
}

// SubmissionResponse is the full representation of a submission, including payload.
// Returned by POST /api/v1/reviews, POST /api/v1/frictions, and
// GET /api/v1/submissions/{id}.
type SubmissionResponse struct {
	ID               int64          `json:"id"`
	SubmissionType   string         `json:"submission_type"`
	MachineName      string         `json:"machine_name"`
	CoordinatorModel string         `json:"coordinator_model"`
	RunID            *string        `json:"run_id,omitempty"`
	Payload          map[string]any `json:"payload"`
	CreatedAt        time.Time      `json:"created_at"`
}

// SubmissionSummaryResponse is the list representation of a submission, excluding
// payload, returned by GET /api/v1/submissions.
type SubmissionSummaryResponse struct {
	ID               int64     `json:"id"`
	SubmissionType   string    `json:"submission_type"`
	MachineName      string    `json:"machine_name"`
	CoordinatorModel string    `json:"coordinator_model"`
	RunID            *string   `json:"run_id,omitempty"`
	CreatedAt        time.Time `json:"created_at"`
}

// ListSubmissionsResponse is the response body for GET /api/v1/submissions.
type ListSubmissionsResponse struct {
	Submissions []SubmissionSummaryResponse `json:"submissions"`
	Limit       int                         `json:"limit"`
	Offset      int                         `json:"offset"`
}

// ErrorResponse is the standard error response.
type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}
