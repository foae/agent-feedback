package core

// ReviewerInput is a single reviewer's contribution to a review submission.
// Marshaled verbatim (alongside Prompt) into the submissions.payload JSONB column.
type ReviewerInput struct {
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

// CreateReviewInput is the validated input for CreateReview.
type CreateReviewInput struct {
	Skill            string
	MachineName      string
	CoordinatorModel string
	RunID            string
	Prompt           string
	Reviewers        []ReviewerInput
}

// reviewPayload is the JSON shape stored in submissions.payload for review submissions.
type reviewPayload struct {
	Prompt    string          `json:"prompt,omitempty"`
	Reviewers []ReviewerInput `json:"reviewers"`
}

// CreateFrictionInput is the validated input for CreateFriction.
type CreateFrictionInput struct {
	MachineName      string
	CoordinatorModel string
	Category         string
	Summary          string
	Details          string
	SuggestedFix     string
	Project          string
	Harness          string
}

// frictionPayload is the JSON shape stored in submissions.payload for friction submissions.
type frictionPayload struct {
	Category     string `json:"category"`
	Summary      string `json:"summary"`
	Details      string `json:"details,omitempty"`
	SuggestedFix string `json:"suggested_fix,omitempty"`
	Project      string `json:"project,omitempty"`
	Harness      string `json:"harness,omitempty"`
}
